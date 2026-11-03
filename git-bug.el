;;; git-bug.el --- Magit sections for git-bug bugs -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, vc
;; Package-Requires: ((emacs "31.1") (magit "4.0.0"))
;; URL: https://github.com/nagy/emacs-git-bug

;;; Commentary:

;; Magit extension for the git-bug distributed bug tracker.  It adds a
;; "Bugs" section to `magit-status' buffers listing the bugs stored in
;; the repository's `refs/bugs/*' references, shelling out to the
;; git-bug command-line tool behind the scenes.
;;
;; Usage:
;;
;;   (add-hook 'magit-status-sections-hook #'git-bug-insert-status-bugs 100)
;;
;; Every bug is a collapsible section; expand it to see its labels,
;; description and comments.  Bug bodies are fontified as Markdown
;; with the builtin `markdown-ts-mode', when its tree-sitter grammars
;; are installed; markup symbols are then hidden.  On a bug heading,
;; `RET' copies the short id and `x' flips the open/closed status.
;;
;; Which bugs are listed is controlled by `git-bug-status-section-scope'.
;; When this package is built with Nix, `git-bug-program' is rewritten
;; to the absolute store path of the git-bug binary, so nothing has to
;; be present on `exec-path'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magit)
(require 'markdown-ts-mode)
(require 'subr-x)

(defgroup git-bug nil
  "Git-bug sections for Magit."
  :group 'tools
  :prefix "git-bug-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/emacs-git-bug"))

(define-error 'git-bug-error "Git-bug error")

(defcustom git-bug-program "git-bug"
  "The git-bug executable used to interact with bugs.
When this package is built with Nix, this is rewritten to the
absolute store path of the git-bug binary at build time."
  :type 'file
  :group 'git-bug)

(defcustom git-bug-status-section-scope 'open
  "Which bugs `git-bug-insert-status-bugs' lists.
One of the symbols `open', `closed' or `all'.  The heading of the
section always shows the number of listed bugs over the number of
all bugs."
  :type '(choice (const :tag "Open bugs" open)
                 (const :tag "Closed bugs" closed)
                 (const :tag "All bugs" all))
  :group 'git-bug)

(defcustom git-bug-status-section-verbose nil
  "Whether to report git-bug failures in the echo area."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-show-empty t
  "Whether to show the Bugs section in a repository without bugs."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-show-errors t
  "Whether to show the Bugs section when git-bug fails."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-group-by-status nil
  "Whether to group the all-bugs scope into Open and Closed sections."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-sort 'edit-time
  "How `git-bug-insert-status-bugs' sorts bugs."
  :type '(choice (const :tag "Last edited" edit-time)
                 (const :tag "Created" create-time)
                 (const :tag "Title" title)
                 (const :tag "Status" status)
                 (const :tag "Id" id))
  :group 'git-bug)

(defcustom git-bug-status-section-label nil
  "Only list bugs with this label, or nil for any label."
  :type '(choice (const :tag "Any label" nil) string)
  :group 'git-bug)

(defcustom git-bug-status-section-author nil
  "Only list bugs whose author matches this string, or nil.
Matching is case-insensitive against name, login and human id."
  :type '(choice (const :tag "Any author" nil) string)
  :group 'git-bug)

(defclass git-bug-bugs-section (magit-section)
  ((keymap :initform 'git-bug-bugs-section-map))
  "Class for the section listing the bugs of a repository.")

(defclass git-bug-bug-section (magit-section)
  ((keymap :initform 'git-bug-bug-section-map))
  "Class for a single bug.")

(defclass git-bug-status-group-section (magit-section) ()
  "Class for an Open or Closed group of bugs.")

(defun git-bug--call (repo &rest args)
  "Run git-bug with ARGS in REPO and return its standard output.
Standard error goes to a temporary file: the split-destination
form of `process-file' only accepts file names for it, and
git-bug prints progress noise there anyway.  Signal
`git-bug-error' when git-bug exits with a non-zero status."
  (apply #'git-bug--call-with-input repo nil args))

(defun git-bug--process-environment ()
  "Return `process-environment' with quiet git settings prepended."
  (cons "GIT_OPTIONAL_LOCKS=0"
        (cons "PAGER=cat"
              (cons "GIT_PAGER=cat" process-environment))))

(defun git-bug--call-with-input (repo input &rest args)
  "Run git-bug with ARGS in REPO, feeding INPUT to standard input.
Return standard output.  Signal `git-bug-error' when git-bug exits
with a non-zero status."
  (let ((stderr (make-temp-file "git-bug-stderr"))
        (stdin (and input (make-temp-file "git-bug-stdin"))))
    (unwind-protect
        (progn
          (when stdin
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file stdin
                (insert input))))
          (with-temp-buffer
            (let* ((default-directory (file-name-as-directory repo))
                   (process-environment (git-bug--process-environment))
                   (coding-system-for-read 'utf-8-unix)
                   (coding-system-for-write 'utf-8-unix)
                   (exit (apply #'process-file git-bug-program stdin
                                (list t stderr) nil args)))
              (unless (eq exit 0)
                (let ((err (string-trim (git-bug--read-file stderr))))
                  (signal 'git-bug-error
                          (list (format "Git-bug %s failed: %s"
                                        (string-join args " ")
                                        (if (string-empty-p err)
                                            (string-trim (buffer-string))
                                          err))))))
              (buffer-string))))
      (delete-file stderr)
      (when stdin
        (delete-file stdin)))))

(defun git-bug--read-file (file)
  "Return the contents of FILE as a string."
  (let ((coding-system-for-read 'utf-8-unix))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun git-bug--parse-json (string)
  "Parse JSON STRING into Lisp data.
Objects become alists keyed by symbols, arrays become lists and
JSON null becomes nil."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun git-bug--git-dir (repo)
  "Return the absolute git directory of REPO, or nil."
  (let ((default-directory (file-name-as-directory repo)))
    (ignore-errors (magit-git-string "rev-parse" "--absolute-git-dir"))))

(defun git-bug--initialized-p (repo)
  "Return non-nil when REPO contains git-bug state.
That means bug refs or a git-bug cache directory exists.  Other
repositories stay untouched, avoiding cache creation and error
noise from a global `magit-status-sections-hook' entry."
  (condition-case nil
      (let ((default-directory (file-name-as-directory repo)))
        (or (magit-git-string "for-each-ref" "--count=1" "refs/bugs")
            (when-let* ((dir (git-bug--git-dir repo)))
              (file-directory-p (expand-file-name "git-bug" dir)))))
    (error nil)))

(defun git-bug--list (repo)
  "Return all bugs in REPO as a list of alists.
Return nil when REPO contains no bugs.  Signal `git-bug-error'
when git-bug fails."
  (let ((out (git-bug--call repo "bug" "--format" "json")))
    (unless (string-blank-p out)
      (git-bug--parse-json out))))

(defun git-bug--bug-author-fields (bug)
  "Return the author fields of BUG for filtering."
  (declare (pure t) (side-effect-free t))
  (let ((author (alist-get 'author bug)))
    (list (alist-get 'name author)
          (alist-get 'login author)
          (alist-get 'human_id author))))

(defun git-bug--filter-bugs (bugs)
  "Return BUGS matching the label and author filters."
  (declare (side-effect-free t))
  (cl-remove-if-not
   (lambda (bug)
     (and (or (null git-bug-status-section-label)
              (member git-bug-status-section-label
                      (alist-get 'labels bug)))
          (or (null git-bug-status-section-author)
              (let ((needle (downcase git-bug-status-section-author)))
                (cl-some (lambda (field)
                           (and (stringp field)
                                (string-match-p
                                 (regexp-quote needle)
                                 (downcase field))))
                         (git-bug--bug-author-fields bug))))))
   bugs))

(defun git-bug--bug-time (key bug)
  "Return the timestamp of KEY in BUG, or zero."
  (declare (pure t) (side-effect-free t))
  (or (alist-get 'timestamp (alist-get key bug)) 0))

(defun git-bug--sort-bugs (bugs)
  "Return BUGS sorted according to `git-bug-status-section-sort'."
  (declare (side-effect-free t))
  (let ((sorted (copy-sequence bugs)))
    (pcase git-bug-status-section-sort
      ('edit-time
       (sort sorted (lambda (a b)
                      (> (git-bug--bug-time 'edit_time a)
                         (git-bug--bug-time 'edit_time b)))))
      ('create-time
       (sort sorted (lambda (a b)
                      (> (git-bug--bug-time 'create_time a)
                         (git-bug--bug-time 'create_time b)))))
      ('title
       (sort sorted (lambda (a b)
                      (string-lessp
                       (downcase (or (alist-get 'title a) ""))
                       (downcase (or (alist-get 'title b) ""))))))
      ('status
       (sort sorted (lambda (a b)
                      (let ((sa (or (alist-get 'status a) ""))
                            (sb (or (alist-get 'status b) "")))
                        (if (equal sa sb)
                            (> (git-bug--bug-time 'edit_time a)
                               (git-bug--bug-time 'edit_time b))
                          (string-lessp sa sb))))))
      ('id
       (sort sorted (lambda (a b)
                      (string-lessp (or (alist-get 'id a) "")
                                    (or (alist-get 'id b) "")))))
      (_ sorted))))

(defun git-bug--displayed-bugs (bugs)
  "Return BUGS after filtering and sorting."
  (declare (side-effect-free t))
  (git-bug--sort-bugs (git-bug--filter-bugs bugs)))

(defun git-bug--select (bugs scope)
  "Return the BUGS matching SCOPE.
BUGS is a list of bug alists as returned by `git-bug--list'.
SCOPE is one of the symbols `open', `closed' or `all'."
  (declare (pure t) (side-effect-free t))
  (pcase scope
    ('all bugs)
    ('open (cl-remove-if-not
            (lambda (bug) (equal (alist-get 'status bug) "open"))
            bugs))
    ('closed (cl-remove-if-not
              (lambda (bug) (equal (alist-get 'status bug) "closed"))
              bugs))
    (_ (error "Invalid bug scope: %S" scope))))

(defvar git-bug--detail-cache (make-hash-table :test #'equal)
  "Cache of bug details keyed by repo, id and edit time.")

(defconst git-bug--detail-cache-limit 500
  "Maximum number of entries in `git-bug--detail-cache'.")

(defun git-bug--fetch-detail (repo id)
  "Fetch the full bug ID in REPO as an alist."
  (git-bug--parse-json
   (git-bug--call repo "bug" "show" id "--format" "json")))

(defun git-bug--detail (repo id &optional edit-time force)
  "Return the full bug ID in REPO as an alist.
Unlike the entries returned by `git-bug--list', the result includes
the labels and the comments; comment number zero is the bug
description.  Cache the result when EDIT-TIME is non-nil, unless
FORCE is non-nil."
  (let ((key (list repo id edit-time)))
    (if (and edit-time (not force))
        (or (gethash key git-bug--detail-cache)
            (progn
              (when (>= (hash-table-count git-bug--detail-cache)
                        git-bug--detail-cache-limit)
                (clrhash git-bug--detail-cache))
              (puthash key (git-bug--fetch-detail repo id)
                       git-bug--detail-cache)))
      (git-bug--fetch-detail repo id))))

(defun git-bug--set-status (repo id status)
  "Set the status of bug ID in REPO to STATUS.
STATUS is either \"open\" or \"close\", matching the git-bug
command line."
  (git-bug--call repo "bug" "status" status id))

(defun git-bug--markdown-ts-ready-p ()
  "Return non-nil when markdown fontification is available.
That is the case when the builtin `markdown-ts-mode' exists and
both of the tree-sitter grammars it needs, `markdown' and
`markdown-inline', are installed."
  (and (fboundp 'markdown-ts-mode)
       (treesit-available-p)
       ;; `treesit-language-available-p' with DETAIL returns (nil . DATA)
       ;; when the grammar is missing.  `car' extracts the boolean.
       (car (treesit-language-available-p 'markdown t))
       (car (treesit-language-available-p 'markdown-inline t))))

(defun git-bug--fontify-markdown (string)
  "Return STRING with Markdown syntax highlighting applied.
Fontification runs STRING through `markdown-ts-mode' in a
temporary buffer with `markdown-ts-hide-markup' enabled: markup
symbols (backticks, emphasis markers, ...) get an `invisible'
property of t, which hides them unconditionally in the target
buffer.  The `face' properties of the mode are copied to
`font-lock-face', which refontification does not strip (see
`font-lock-default-unfontify-region').

Return STRING unchanged when the tree-sitter grammars are not
installed (see `git-bug--markdown-ts-ready-p') or when the mode
signals an error."
  (if (not (git-bug--markdown-ts-ready-p))
      string
    (condition-case nil
        (let ((markdown-ts-hide-markup t)
              ;; Activating an embedded mode for a fenced block can
              ;; prompt to install its grammar and discard the whole
              ;; fontification on failure.  Keep bodies in Markdown.
              (markdown-ts-fontify-code-blocks-natively nil)
              ;; Bug bodies are untrusted.  Do not fetch images, fold
              ;; headings, or enable editing helpers in this buffer.
              (markdown-ts-inline-images nil)
              (markdown-ts-display-remote-inline-images nil)
              (markdown-ts-default-folding 'show-all)
              (markdown-ts-enable-code-block-context-mode nil)
              (markdown-ts-enable-table-mode nil))
          (with-temp-buffer
            (insert string)
            (delay-mode-hooks (markdown-ts-mode))
            (font-lock-ensure)
            (let ((out (copy-sequence string))
                  (pos (point-min)))
              (while (< pos (point-max))
                (let* ((end (or (next-property-change pos) (point-max)))
                       (face (get-text-property pos 'face))
                       (hidden (get-text-property pos 'invisible)))
                  ;; Buffer position POS is string index (1- POS).
                  (when face
                    (put-text-property (1- pos) (1- end)
                                       'font-lock-face face out))
                  (when hidden
                    (put-text-property (1- pos) (1- end) 'invisible t out))
                  ;; Keep Markdown link buttons usable.  Do not copy
                  ;; `display': bug bodies stay free of images.
                  (dolist (prop '(help-echo action category button
                                  mouse-face keymap))
                    (when-let* ((value (get-text-property pos prop)))
                      (put-text-property (1- pos) (1- end) prop value out)))
                  (setq pos end)))
              out)))
      (error string))))

(defun git-bug--author-display (author)
  "Return a cons of AUTHOR display text and face.
AUTHOR is a git-bug actor alist.  Fall back from name to login to
human id and finally to a literal placeholder."
  (declare (pure t) (side-effect-free t))
  (let ((name (alist-get 'name author))
        (login (alist-get 'login author))
        (id (alist-get 'human_id author)))
    (cond ((and (stringp name) (not (string-empty-p name)))
           (cons name 'magit-dimmed))
          ((and (stringp login) (not (string-empty-p login)))
           (cons login 'magit-dimmed))
          ((and (stringp id) (not (string-empty-p id)))
           (cons id 'magit-hash))
          (t (cons "unknown" 'magit-hash)))))

(defun git-bug--clean-title (title)
  "Return TITLE on one line."
  (declare (pure t) (side-effect-free t))
  (string-trim (replace-regexp-in-string "[\r\n]+" " " (or title ""))))

(defun git-bug--sorted-labels (labels)
  "Return a sorted copy of LABELS."
  (declare (pure t) (side-effect-free t))
  (sort (copy-sequence labels) #'string<))

(defun git-bug--insert-detail (detail)
  "Insert the labels, description and comments of DETAIL.
DETAIL is a bug alist as returned by `git-bug--detail'."
  (when-let* ((labels (alist-get 'labels detail)))
    (insert (propertize
             (format "Labels: %s"
                     (string-join (git-bug--sorted-labels labels) ", "))
             'font-lock-face 'magit-tag))
    (insert "\n"))
  (let ((comments (alist-get 'comments detail)))
    ;; Comment number zero is the bug description.
    (when-let* ((body (car comments)))
      (insert (git-bug--fontify-markdown (alist-get 'message body)) "\n"))
    (cl-loop
     for comment in (cdr comments)
     for n from 1
     for author = (alist-get 'author comment)
     for display = (git-bug--author-display author)
     do (insert "\n")
        (insert (propertize (format "#%d " n) 'font-lock-face 'magit-dimmed)
                (propertize (car display) 'font-lock-face (cdr display))
                (propertize ":" 'font-lock-face 'magit-dimmed))
        (insert "\n")
        (insert (git-bug--fontify-markdown (alist-get 'message comment))
                "\n"))))

(defun git-bug--format-time (object)
  "Return the timestamp in OBJECT as a readable string."
  (let ((timestamp (alist-get 'timestamp object)))
    (if timestamp
        (format-time-string "%Y-%m-%d %H:%M" timestamp)
      "unknown")))

(defun git-bug--insert-bug-buffer (detail)
  "Insert the full rendered DETAIL into the current buffer."
  (let* ((title (git-bug--clean-title (alist-get 'title detail)))
         (id (or (alist-get 'human_id detail) ""))
         (status (or (alist-get 'status detail) "unknown"))
         (author (git-bug--author-display (alist-get 'author detail)))
         (created (git-bug--format-time (alist-get 'create_time detail)))
         (edited (git-bug--format-time (alist-get 'edit_time detail))))
    (insert (propertize title 'font-lock-face 'magit-section-heading) "\n")
    (insert (propertize id 'font-lock-face 'magit-hash)
            " "
            (propertize status
                        'font-lock-face (if (equal status "open")
                                            'success
                                          'magit-dimmed))
            "\n")
    (insert (propertize (format "Author: %s" (car author))
                        'font-lock-face (cdr author))
            "\n")
    (insert (propertize (format "Created: %s\nEdited: %s\n" created edited)
                        'font-lock-face 'magit-dimmed))
    (when-let* ((participants (alist-get 'participants detail)))
      (insert (propertize
               (format "Participants: %s"
                       (string-join
                        (mapcar (lambda (person)
                                  (car (git-bug--author-display person)))
                                participants)
                        ", "))
               'font-lock-face 'magit-dimmed))
      (insert "\n"))
    (insert "\n")
    (git-bug--insert-detail detail)))

(defvar-local git-bug--buffer-repo nil
  "Repository of the bug shown in this buffer.")

(defvar-local git-bug--buffer-id nil
  "Full id of the bug shown in this buffer.")

(defvar-local git-bug--buffer-human-id nil
  "Short id of the bug shown in this buffer.")

(defvar-local git-bug--buffer-status nil
  "Status of the bug shown in this buffer.")

(defvar-local git-bug--buffer-edit-time nil
  "Edit timestamp of the bug shown in this buffer.")

(defvar-keymap git-bug-mode-map
  :doc "Keymap for `git-bug-mode'."
  :parent special-mode-map
  "q" #'quit-window
  "g" #'git-bug-refresh-buffer
  "w" #'git-bug-copy-id-at-point
  "W" #'git-bug-copy-full-id-at-point
  "C-c r" #'git-bug-copy-ref-at-point
  "x" #'git-bug-toggle-status-in-buffer
  "c" #'git-bug-add-comment-at-point
  "l" #'git-bug-edit-labels-at-point)

(define-derived-mode git-bug-mode special-mode "Git-Bug"
  "Major mode for viewing a single bug."
  (setq-local buffer-read-only t)
  (visual-line-mode 1))

(defun git-bug-refresh-buffer (&optional force)
  "Refresh the current `git-bug-mode' buffer from git-bug.
With FORCE, ignore the detail cache."
  (interactive "P")
  (unless (derived-mode-p 'git-bug-mode)
    (user-error "Not a git-bug buffer"))
  (let ((detail (git-bug--detail git-bug--buffer-repo
                                 git-bug--buffer-id
                                 git-bug--buffer-edit-time
                                 force)))
    (setq-local git-bug--buffer-status (alist-get 'status detail))
    (setq-local git-bug--buffer-edit-time
                (alist-get 'timestamp (alist-get 'edit_time detail)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (git-bug--insert-bug-buffer detail)
      (goto-char (point-min)))))

(defun git-bug-toggle-status-in-buffer ()
  "Toggle the status of the bug in the current `git-bug-mode' buffer."
  (interactive)
  (unless (derived-mode-p 'git-bug-mode)
    (user-error "Not a git-bug buffer"))
  (git-bug--set-status git-bug--buffer-repo
                       git-bug--buffer-id
                       (if (equal git-bug--buffer-status "open")
                           "close"
                         "open"))
  (git-bug-refresh-buffer t))

(defun git-bug-show-bug (repo bug)
  "Show BUG from REPO in a dedicated `git-bug-mode' buffer."
  (let* ((id (alist-get 'id bug))
         (human (alist-get 'human_id bug))
         (buffer (get-buffer-create
                  (format "*git-bug: %s*" (or human id)))))
    (with-current-buffer buffer
      (git-bug-mode)
      (setq-local default-directory (file-name-as-directory repo))
      (setq-local git-bug--buffer-repo repo
                  git-bug--buffer-id id
                  git-bug--buffer-human-id human
                  git-bug--buffer-edit-time (git-bug--bug-edit-time bug))
      (git-bug-refresh-buffer))
    (pop-to-buffer buffer)))

(defun git-bug-show-bug-at-point ()
  "Show the bug at point in a dedicated buffer."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (git-bug-show-bug (magit-toplevel) bug)
    (user-error "No bug at point")))

(defvar-local git-bug--compose-callback nil
  "Function called with the composed text on submit.")

(defvar-keymap git-bug-compose-mode-map
  :doc "Keymap for `git-bug-compose-mode'."
  :parent text-mode-map
  "C-c C-c" #'git-bug-compose-submit
  "C-c C-k" #'git-bug-compose-cancel)

(define-derived-mode git-bug-compose-mode text-mode "Git-Bug-Compose"
  "Major mode for composing a git-bug message."
  (setq-local header-line-format
              (substitute-command-keys
               "\[git-bug-compose-submit] submit  \[git-bug-compose-cancel] cancel")))

(defun git-bug--compose (description initial callback)
  "Open a compose buffer with DESCRIPTION, INITIAL text and CALLBACK."
  (let ((buffer (get-buffer-create "*git-bug compose*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert initial)
      (git-bug-compose-mode)
      (setq-local git-bug--compose-callback callback)
      (setq-local header-line-format
                  (format "%s  %s" description
                          (substitute-command-keys
                           "\[git-bug-compose-submit] submit  \[git-bug-compose-cancel] cancel")))
      (goto-char (point-max)))
    (pop-to-buffer buffer)))

(defun git-bug-compose-submit ()
  "Submit the current compose buffer."
  (interactive)
  (let ((text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "Empty message"))
    (funcall git-bug--compose-callback text)
    (kill-buffer (current-buffer))))

(defun git-bug-compose-cancel ()
  "Cancel the current compose buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(defun git-bug--refresh-after-write (repo)
  "Refresh a `magit-status-mode' buffer for REPO, when one exists."
  (let ((buffer (cl-find-if
                 (lambda (candidate)
                   (with-current-buffer candidate
                     (and (derived-mode-p 'magit-status-mode)
                          (ignore-errors
                            (equal (magit-toplevel) repo)))))
                 (buffer-list))))
    (cond (buffer
           (with-current-buffer buffer
             (magit-refresh)))
          ((derived-mode-p 'magit-mode)
           (magit-refresh)))))

(defun git-bug--create-bug (repo title body)
  "Create a bug in REPO with TITLE and BODY and return its short id.
Git-bug takes the title from the first line of the message."
  (let ((out (git-bug--call-with-input
              repo (concat (git-bug--clean-title title) "\n\n" body)
              "bug" "new" "--non-interactive" "-F" "-")))
    (car (split-string out))))

;;;###autoload
(defun git-bug-new-bug ()
  "Create a new git-bug bug in the current repository."
  (interactive)
  (let ((repo (magit-toplevel)))
    (unless repo
      (user-error "Not inside a Git repository"))
    (let ((title (string-trim (read-string "Bug title: "))))
      (when (string-empty-p title)
        (user-error "Empty title"))
      (git-bug--compose
       (format "New bug: %s" title)
       ""
       (lambda (body)
         (let ((id (git-bug--create-bug repo title body)))
           (git-bug--refresh-after-write repo)
           (message "Created bug %s" id)))))))

(defun git-bug--current-bug ()
  "Return (REPO ID HUMAN-ID) for the bug at point."
  (cond
   ((derived-mode-p 'git-bug-mode)
    (list git-bug--buffer-repo
          git-bug--buffer-id
          git-bug--buffer-human-id))
   ((magit-section-value-if 'git-bug-bug-section)
    (let ((bug (magit-section-value-if 'git-bug-bug-section)))
      (list (magit-toplevel)
            (alist-get 'id bug)
            (alist-get 'human_id bug))))
   (t (user-error "No bug at point"))))

(defun git-bug--add-comment (repo id body)
  "Add BODY as a comment to bug ID in REPO."
  (git-bug--call-with-input
   repo body "bug" "comment" "new" id "--non-interactive" "-F" "-"))

(defun git-bug--set-labels (repo id labels)
  "Set the labels of bug ID in REPO to LABELS."
  (let* ((detail (git-bug--detail repo id))
         (current (alist-get 'labels detail))
         (added (cl-set-difference labels current :test #'equal))
         (removed (cl-set-difference current labels :test #'equal)))
    (when added
      (apply #'git-bug--call repo "bug" "label" "new" id added))
    (when removed
      (apply #'git-bug--call repo "bug" "label" "rm" id removed))))

(defun git-bug--after-bug-change (repo human-id)
  "Refresh the status section and viewer buffer for HUMAN-ID after a write to REPO."
  (git-bug--refresh-after-write repo)
  (when-let* ((buffer (get-buffer (format "*git-bug: %s*" human-id)))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'git-bug-mode)
        (git-bug-refresh-buffer t)))))

;;;###autoload
(defun git-bug-add-comment-at-point ()
  "Add a comment to the bug at point."
  (interactive)
  (pcase-let ((`(,repo ,id ,human) (git-bug--current-bug)))
    (git-bug--compose
     (format "Comment on %s" human)
     ""
     (lambda (body)
       (git-bug--add-comment repo id body)
       (git-bug--after-bug-change repo human)))))

;;;###autoload
(defun git-bug-edit-labels-at-point ()
  "Edit the labels of the bug at point."
  (interactive)
  (pcase-let ((`(,repo ,id ,human) (git-bug--current-bug)))
    (let* ((detail (git-bug--detail repo id))
           (current (git-bug--sorted-labels
                     (copy-sequence (alist-get 'labels detail))))
           (value (completing-read-multiple
                   "Labels: " nil nil nil
                   (string-join current ","))))
      (git-bug--set-labels
       repo id
       (cl-remove-if #'string-empty-p
                     (mapcar #'string-trim value)))
      (git-bug--after-bug-change repo human))))

(defun git-bug--comment-count (bug)
  "Return the number of replies in BUG."
  (declare (pure t) (side-effect-free t))
  (let ((comments (alist-get 'comments bug)))
    (if (numberp comments) (max 0 (1- comments)) 0)))

(defun git-bug--age-string (timestamp)
  "Return a short relative age for TIMESTAMP, or an empty string."
  (if (not (numberp timestamp))
      ""
    (let ((delta (max 0 (floor (- (float-time) timestamp)))))
      (cond ((< delta 60) "now")
            ((< delta 3600) (format "%dm" (/ delta 60)))
            ((< delta 86400) (format "%dh" (/ delta 3600)))
            ((< delta 2592000) (format "%dd" (/ delta 86400)))
            (t (format "%dmo" (/ delta 2592000)))))))

(defun git-bug--heading-extras (bug)
  "Return propertized labels, reply count and age for BUG."
  (let* ((labels (git-bug--sorted-labels (alist-get 'labels bug)))
         (comments (git-bug--comment-count bug))
         (age (git-bug--age-string
               (alist-get 'timestamp (alist-get 'edit_time bug)))))
    (concat (when labels
              (concat " " (propertize (format "[%s]" (string-join labels ","))
                                       'font-lock-face 'magit-tag)))
            (when (> comments 0)
              (concat " " (propertize (format "(%d)" comments)
                                       'font-lock-face 'magit-dimmed)))
            (when (not (string-empty-p age))
              (concat " " (propertize age 'font-lock-face 'magit-dimmed))))))

(defun git-bug--refresh-current-status ()
  "Refresh the Magit status buffer associated with the current context."
  (cond ((derived-mode-p 'magit-mode)
         (magit-refresh))
        ((ignore-errors (magit-toplevel))
         (git-bug--refresh-after-write (magit-toplevel)))))

(defun git-bug-set-scope ()
  "Set `git-bug-status-section-scope' interactively."
  (interactive)
  (setq git-bug-status-section-scope
        (intern (completing-read
                 "Bug scope: " '("open" "closed" "all") nil t nil nil
                 (symbol-name git-bug-status-section-scope))))
  (git-bug--refresh-current-status))

(defun git-bug--all-labels (bugs)
  "Return all labels in BUGS, sorted and unique."
  (declare (pure t) (side-effect-free t))
  (let (labels)
    (dolist (bug bugs)
      (setq labels (append (alist-get 'labels bug) labels)))
    (sort (delete-dups labels) #'string<)))

(defun git-bug--all-authors (bugs)
  "Return all author names in BUGS, sorted and unique."
  (declare (pure t) (side-effect-free t))
  (let (names)
    (dolist (bug bugs)
      (let ((name (car (git-bug--author-display (alist-get 'author bug)))))
        (unless (equal name "unknown")
          (push name names))))
    (sort (delete-dups names) #'string<)))

(defun git-bug-filter-label (&optional clear)
  "Filter bugs by label, or clear the filter with prefix CLEAR."
  (interactive "P")
  (if clear
      (setq git-bug-status-section-label nil)
    (let* ((bugs (git-bug--list (magit-toplevel)))
           (value (completing-read
                   "Label: " (git-bug--all-labels bugs) nil nil nil nil
                   git-bug-status-section-label)))
      (setq git-bug-status-section-label
            (if (string-empty-p value) nil value))))
  (git-bug--refresh-current-status))

(defun git-bug-filter-author (&optional clear)
  "Filter bugs by author, or clear the filter with prefix CLEAR."
  (interactive "P")
  (if clear
      (setq git-bug-status-section-author nil)
    (let* ((bugs (git-bug--list (magit-toplevel)))
           (value (completing-read
                   "Author: " (git-bug--all-authors bugs) nil nil nil nil
                   git-bug-status-section-author)))
      (setq git-bug-status-section-author
            (if (string-empty-p value) nil value))))
  (git-bug--refresh-current-status))

(defun git-bug-set-sort ()
  "Set `git-bug-status-section-sort' interactively."
  (interactive)
  (setq git-bug-status-section-sort
        (intern (completing-read
                 "Sort bugs by: "
                 '("edit-time" "create-time" "title" "status" "id")
                 nil t nil nil
                 (symbol-name git-bug-status-section-sort))))
  (git-bug--refresh-current-status))

(defun git-bug-clear-filters ()
  "Clear label and author filters."
  (interactive)
  (setq git-bug-status-section-label nil
        git-bug-status-section-author nil)
  (git-bug--refresh-current-status))

(defun git-bug--bug-edit-time (bug)
  "Return the edit timestamp of BUG."
  (declare (pure t) (side-effect-free t))
  (alist-get 'timestamp (alist-get 'edit_time bug)))

(defun git-bug--insert-bug (repo bug)
  "Insert BUG from REPO as a collapsed `git-bug-bug-section'."
  (magit-insert-section (git-bug-bug-section bug 'hide)
    (let ((id (or (alist-get 'human_id bug) ""))
          (bug-id (alist-get 'id bug))
          (status (or (alist-get 'status bug) "unknown")))
      ;; Note the `font-lock-face' property, not `face': font-lock
      ;; refontification strips `face', leaving the ids unfontified.
      (magit-insert-heading
       (concat (propertize id 'font-lock-face 'magit-hash)
               " "
               (propertize (format "%-6s" status)
                           'font-lock-face (if (equal status "open")
                                               'success
                                             'magit-dimmed))
               " "
               (propertize (git-bug--clean-title (alist-get 'title bug))
                           'font-lock-face 'magit-section-heading)
               (git-bug--heading-extras bug)))
      ;; Magit runs this body only when the user expands the section.
      ;; Fetching details for every collapsed bug blocks `magit-status'.
      (magit-insert-section-body
        (condition-case err
            (git-bug--insert-detail
             (git-bug--detail repo bug-id (git-bug--bug-edit-time bug)))
          (error
           (insert (propertize
                    (format "Details unavailable: %s\n"
                            (error-message-string err))
                    'font-lock-face 'error))))))))

(defun git-bug--insert-group (repo label bugs)
  "Insert a status group named LABEL with BUGS from REPO."
  (magit-insert-section (git-bug-status-group-section)
    (magit-insert-heading (format "%s (%d)" label (length bugs)))
    (dolist (bug bugs)
      (git-bug--insert-bug repo bug))
    (insert ?\n)))

(defun git-bug--insert-bugs (repo bugs)
  "Insert the Bugs section for BUGS in REPO.
Handle a nil BUGS list when `git-bug-status-section-show-empty' is
non-nil."
  (let* ((scope git-bug-status-section-scope)
         (displayed (and bugs (git-bug--displayed-bugs bugs)))
         (shown (git-bug--select displayed scope)))
    (when (or bugs git-bug-status-section-show-empty)
      (magit-insert-section (git-bug-bugs-section)
        (magit-insert-heading
         (format "Bugs (%d/%d)" (length shown) (length bugs)))
        (cond
         ((null bugs)
          (insert (propertize "No bugs.\n" 'font-lock-face 'magit-dimmed)))
         ((and git-bug-status-section-group-by-status (eq scope 'all))
          (dolist (group '(("Open" . open) ("Closed" . closed)))
            (let ((group-bugs (git-bug--select displayed (cdr group))))
              (when group-bugs
                (git-bug--insert-group repo (car group) group-bugs)))))
         (t
          (dolist (bug shown)
            (git-bug--insert-bug repo bug))))
        (insert ?\n)))))

;;;###autoload
(defun git-bug-insert-status-bugs ()
  "Insert a section listing the git-bug bugs of the repository.
Meant for `magit-status-sections-hook'.  Which bugs are listed is
controlled by `git-bug-status-section-scope'; the heading always
shows the number of listed bugs over the number of all bugs."
  (when-let* ((repo (magit-toplevel))
              ((git-bug--initialized-p repo)))
    (condition-case err
        (git-bug--insert-bugs repo (git-bug--list repo))
      (error
       (when git-bug-status-section-verbose
         (message "Git-bug: %s" (error-message-string err)))
       (when git-bug-status-section-show-errors
         (magit-insert-section (git-bug-bugs-section)
           (magit-insert-heading "Bugs (unavailable)")
           (insert (propertize
                    (format "Git-bug failed: %s\n"
                            (error-message-string err))
                    'font-lock-face 'error))))))))

(defun git-bug--current-bug-reference (kind)
  "Return the KIND reference for the bug at point.
KIND is `short', `full' or `ref'."
  (cond
   ((derived-mode-p 'git-bug-mode)
    (pcase kind
      ('short git-bug--buffer-human-id)
      ('full git-bug--buffer-id)
      ('ref (format "refs/bugs/%s" git-bug--buffer-id))))
   ((magit-section-value-if 'git-bug-bug-section)
    (let ((bug (magit-section-value-if 'git-bug-bug-section)))
      (pcase kind
        ('short (alist-get 'human_id bug))
        ('full (alist-get 'id bug))
        ('ref (format "refs/bugs/%s" (alist-get 'id bug))))))
   (t (user-error "No bug at point"))))

(defun git-bug--copy-reference (kind)
  "Copy the KIND reference of the bug at point."
  (let ((value (git-bug--current-bug-reference kind)))
    (kill-new value)
    (message "Copied %s" value)))

;;;###autoload
(defun git-bug-copy-id-at-point (&optional arg)
  "Copy the short id of the bug at point.
With one prefix ARG copy the full id.  With two prefix arguments
copy the bug ref."
  (interactive "P")
  (git-bug--copy-reference
   (cond ((equal arg '(16)) 'ref)
         ((equal arg '(4)) 'full)
         (t 'short))))

;;;###autoload
(defun git-bug-copy-full-id-at-point ()
  "Copy the full id of the bug at point."
  (interactive)
  (git-bug--copy-reference 'full))

;;;###autoload
(defun git-bug-copy-ref-at-point ()
  "Copy the git ref of the bug at point."
  (interactive)
  (git-bug--copy-reference 'ref))

;;;###autoload
(defun git-bug-toggle-status-at-point ()
  "Toggle the open/closed status of the bug at point."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (progn
        (git-bug--set-status (magit-toplevel)
                             (alist-get 'id bug)
                             (if (equal (alist-get 'status bug) "open")
                                 "close"
                               "open"))
        (when (derived-mode-p 'magit-mode)
          (magit-refresh)))
    (user-error "No bug at point")))

(defvar-keymap git-bug-bug-section-map
  :doc "Keymap for `git-bug-bug-section' headings."
  "RET" #'git-bug-show-bug-at-point
  "w"   #'git-bug-copy-id-at-point
  "W"   #'git-bug-copy-full-id-at-point
  "C-c r" #'git-bug-copy-ref-at-point
  "x"   #'git-bug-toggle-status-at-point
  "c"   #'git-bug-add-comment-at-point
  "l"   #'git-bug-edit-labels-at-point)

(defvar-keymap git-bug-bugs-section-map
  :doc "Keymap for the Bugs section heading."
  "n" #'git-bug-new-bug
  "s" #'git-bug-set-scope
  "l" #'git-bug-filter-label
  "a" #'git-bug-filter-author
  "S" #'git-bug-set-sort
  "c" #'git-bug-clear-filters)

(provide 'git-bug)

;;; git-bug.el ends here
