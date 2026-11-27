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
;;
;; Library:
;;
;; The status section is one consumer of a small public surface.  Read
;; bugs, render them as text and open the viewer without touching a
;; Magit buffer:
;;
;;   (git-bug-list REPO &optional FILTERS)          bugs and their fields
;;   (git-bug-get REPO ID &optional FORCE)          one full bug
;;   (git-bug-field BUG NAME)                       one value of a bug
;;   (git-bug-format-bug BUG &optional FACES)       one heading line
;;   (git-bug-format-bug-list BUGS &optional FACES) every heading line
;;   (git-bug-buffer REPO ID &optional MODE)        a viewer buffer
;;   (git-bug-show REPO ID &optional MODE)          show that buffer
;;   (git-bug-forget &optional REPO ID)             drop cached bugs
;;
;; Every answer keeps the shape of the git-bug JSON, so no accessor
;; hides the wire: `git-bug-list' carries a `comments' count and
;; `git-bug-get' a `comments' list whose first element is the bug
;; description.  `git-bug-field' reads a key by name, ignoring case.
;;
;; Calls block Emacs while git-bug runs; there is no async variant.
;; Cached details live in a hash table, keyed by repository, full id
;; and edit time, and served while `git-bug-detail-ttl' allows.  A
;; write, an explicit forced read or `git-bug-forget' reports one plist
;; per change through `git-bug-change-functions', after the package has
;; refreshed the status section and the open viewers itself.  Failures
;; signal a subtype of `git-bug-error', with the arguments, exit status
;; and stderr of the call in `git-bug-error-data'.

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
(define-error 'git-bug-call-failed "Git-bug call failed" 'git-bug-error)
(define-error 'git-bug-missing-program
  "Git-bug executable not found" 'git-bug-error)
(define-error 'git-bug-invalid-output
  "Unparseable git-bug output" 'git-bug-error)
(define-error 'git-bug-invalid-argument
  "Invalid git-bug argument" 'git-bug-error)

(defun git-bug-error-data (err)
  "Return the context plist attached to condition ERR.
ERR is a condition as `condition-case' binds it.  The keys depend on
the condition: `git-bug-call-failed' carries :args, :exit and
:stderr; `git-bug-missing-program' and `git-bug-invalid-output'
carry :program; `git-bug-invalid-argument' carries :value."
  (cddr err))

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
  "When non-nil, report git-bug failures in the echo area."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-show-empty t
  "When non-nil, show the Bugs section in a repository without bugs."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-show-errors t
  "When non-nil, show the Bugs section when git-bug fails."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-group-by-status nil
  "When non-nil, group the all-bugs scope into Open and Closed sections."
  :type 'boolean
  :group 'git-bug)

(defcustom git-bug-status-section-sort 'edit-time
  "How `git-bug-insert-status-bugs' sorts bugs.
The `label' choice ranks bugs with
`git-bug-status-section-label-order'."
  :type '(choice (const :tag "Last edited" edit-time)
                 (const :tag "Created" create-time)
                 (const :tag "Title" title)
                 (const :tag "Status" status)
                 (const :tag "Label order" label)
                 (const :tag "Id" id))
  :group 'git-bug)

(defcustom git-bug-status-section-label-order nil
  "Rules that rank bugs by label for the `label' sort order.
Each element is a regexp matched against one label at a time, or a
cons of a regexp and a capture group number.  A rule's position
decides the bucket a bug joins, and a rule's capture group decides
the order inside that bucket, so plain regexps sort into priority
buckets and a grouped regexp sorts by the text it captures:

  \='(\"^urgent$\" \"^priority:P1$\" \"^priority:P2$\")
  \='((\"^priority:P\\([0-9]+\\)$\" . 1))

A bug ranks by its best match, so one carrying both `priority:P1'
and `priority:P2' ranks as P1.  A bug that matches no rule sorts
after every bug that does, and the captured text compares with
`string-version-lessp', so P9 precedes P10.  Labels match
case-sensitively.  An empty list leaves bugs in edit-time order."
  :type '(repeat (choice regexp (cons regexp integer)))
  :group 'git-bug)

(defcustom git-bug-status-section-label nil
  "Label that filters the listed bugs, or nil for any label."
  :type '(choice (const :tag "Any label" nil) string)
  :group 'git-bug)

(defcustom git-bug-status-section-author nil
  "Author that filters the listed bugs, or nil for any author.
Matching is case-insensitive against name, login and human id."
  :type '(choice (const :tag "Any author" nil) string)
  :group 'git-bug)

(defgroup git-bug-data nil
  "Reading bugs from git-bug storage."
  :group 'git-bug)

(defcustom git-bug-detail-ttl nil
  "How long, in seconds, a cached bug detail stays fresh.
Nil keeps a cached answer until the bug's edit time changes or the
cache overflows; zero makes every read ask git-bug again.  The
cache fills on reads of `git-bug-get' and of expanded bug
sections, so this only bounds how stale a repeat read can be."
  :type '(choice (const :tag "Forever" nil)
                 (const :tag "Always stale" 0)
                 (number :tag "Seconds"))
  :group 'git-bug-data)

(defcustom git-bug-change-functions nil
  "Abnormal hook run when a bug of the repository changes.
Each function receives one plist with these keys:

  :type   the domain type, always `bug'
  :kind   the answer kind, always `show'
  :event  `create', `change' or `invalidate'
  :repo   the repository of the bug, expanded and without a
          trailing slash
  :id     the full id of the bug
  :old    the detail that goes away, or nil
  :new    the detail that arrives, or nil

The package refreshes the status section and the open viewers
itself, before it runs this hook, so the hook serves consumers that
keep state of their own.  A fetch that returns the cached content
runs nothing.  `create' reports a bug that had no cached answer,
`change' a different answer for a bug that had one, and
`invalidate' an answer that `git-bug-forget' dropped; an
`invalidate' carries no `:new', so a view of that bug keeps its
text until its next read.  A write that the package makes itself
reports `change' even without a cached answer, because it knows
that storage moved; `:old' is then nil.  Writes and external edits
reach a consumer the same way."
  :type 'hook
  :group 'git-bug-data)

(defclass git-bug-bugs-section (magit-section)
  ((keymap :initform 'git-bug-bugs-section-map))
  "Class for the section listing the bugs of a repository.")

(defclass git-bug-bug-section (magit-section)
  ((keymap :initform 'git-bug-bug-section-map))
  "Class for a single bug.")

(defclass git-bug-status-group-section (magit-section) ()
  "Class for an Open or Closed group of bugs.")

(defun git-bug--call (repo &rest args)
  "Run git-bug in REPO with ARGS and return its standard output.
Standard error goes to a temporary file: the split-destination
form of `process-file' only accepts file names for it, and
git-bug prints progress noise there anyway.  Signal the conditions
of `git-bug--call-with-input'."
  (apply #'git-bug--call-with-input repo nil args))

(defun git-bug--process-environment ()
  "Return `process-environment' with quiet git settings prepended."
  (cons "GIT_OPTIONAL_LOCKS=0"
        (cons "PAGER=cat"
              (cons "GIT_PAGER=cat" process-environment))))

(defun git-bug--call-with-input (repo input &rest args)
  "Run git-bug in REPO with INPUT on standard input and ARGS.
Return standard output.  Signal `git-bug-call-failed' when git-bug
exits with a non-zero status, `git-bug-missing-program' when the
executable is absent and `git-bug-invalid-argument' when REPO is
not a directory."
  (unless (file-directory-p repo)
    (signal 'git-bug-invalid-argument
            (list (format "Not a directory: %s" repo) :value repo)))
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
                   (exit (condition-case nil
                             (apply #'process-file git-bug-program stdin
                                    (list t stderr) nil args)
                           (file-missing
                            (signal 'git-bug-missing-program
                                    (list (format "Cannot run git-bug: %s"
                                                  git-bug-program)
                                          :program git-bug-program))))))
              (unless (eq exit 0)
                (let ((err (string-trim (git-bug--read-file stderr))))
                  (signal 'git-bug-call-failed
                          (list (format "Git-bug %s failed: %s"
                                        (string-join args " ")
                                        (if (string-empty-p err)
                                            (string-trim (buffer-string))
                                          err))
                                :args args :exit exit :stderr err))))
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
Objects become alists with symbol keys, arrays become lists and
JSON null becomes nil.  Signal `git-bug-invalid-output' when
STRING is not valid JSON."
  (condition-case err
      (json-parse-string string
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (json-error
     (signal 'git-bug-invalid-output
             (list (format "Cannot parse git-bug output: %s"
                           (error-message-string err))
                   :program git-bug-program)))))

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
Return nil when REPO contains no bugs.  Signal
`git-bug-call-failed' when git-bug fails and `git-bug-invalid-output'
when its answer is not JSON.  The alists keep the keys of the
`git-bug bug --format json' objects; `comments' is a count here and
a list in `git-bug-get'."
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

(defun git-bug--filter-bugs (bugs &optional label author)
  "Return BUGS matching LABEL and AUTHOR.
A nil LABEL or AUTHOR falls back to `git-bug-status-section-label'
or `git-bug-status-section-author'.  LABEL matches a whole label,
case-sensitively; AUTHOR matches case-insensitively against the
name, login and human id of the bug's author."
  (declare (side-effect-free t))
  (let ((label (or label git-bug-status-section-label))
        (author (or author git-bug-status-section-author)))
    (cl-remove-if-not
     (lambda (bug)
       (and (or (null label)
                (member label (alist-get 'labels bug)))
            (or (null author)
                (let ((needle (downcase author)))
                  (cl-some (lambda (field)
                             (and (stringp field)
                                  (string-match-p
                                   (regexp-quote needle)
                                   (downcase field))))
                           (git-bug--bug-author-fields bug))))))
     bugs)))

(defun git-bug--bug-time (key bug)
  "Return the timestamp of KEY in BUG, or zero."
  (declare (pure t) (side-effect-free t))
  (or (alist-get 'timestamp (alist-get key bug)) 0))

(defun git-bug--label-match (label rule)
  "Return LABEL's sort text under RULE, or nil when RULE misses.
RULE is a regexp matched against LABEL, or a cons of a regexp and a
capture group number.  A rule with no group answers the empty
string, so its matches share one sort text."
  (declare (pure t) (side-effect-free t))
  (let* ((regexp (if (consp rule) (car rule) rule))
         (group (and (consp rule) (cdr rule)))
         (case-fold-search nil))
    (save-match-data
      (when (string-match regexp label)
        (or (and group (match-string group label)) "")))))

(defun git-bug--label-rank (label &optional rules)
  "Return the rank of LABEL, or nil when no rule matches it.
RULES defaults to `git-bug-status-section-label-order'.  A rank is
a cons of the index of the first matching rule and the sort text
that rule gives LABEL."
  (declare (side-effect-free t))
  (cl-loop for rule in (or rules git-bug-status-section-label-order)
           for index from 0
           for text = (git-bug--label-match label rule)
           when text
           return (cons index text)))

(defun git-bug--best-label-rank (labels &optional rules)
  "Return the best rank among LABELS, or nil when none matches.
RULES defaults to `git-bug-status-section-label-order'.  The lowest
rule index wins, and the smallest sort text breaks a tie between
two labels one rule matches."
  (declare (side-effect-free t))
  (let (best)
    (dolist (label labels)
      (let ((rank (git-bug--label-rank label rules)))
        (when (and rank
                   (or (null best)
                       (< (car rank) (car best))
                       (and (= (car rank) (car best))
                            (string-version-lessp (cdr rank) (cdr best)))))
          (setq best rank))))
    best))

(defun git-bug--label-sort-key (bug &optional rules)
  "Return the label sort key of BUG as a vector.
RULES defaults to `git-bug-status-section-label-order'.  The vector
holds the rule rank, the captured text and the edit time.  A bug
that matches no rule takes a rank past every rule, so it sorts last."
  (declare (side-effect-free t))
  (let ((rank (git-bug--best-label-rank (alist-get 'labels bug) rules)))
    (vector (if rank (car rank)
              (length (or rules git-bug-status-section-label-order)))
            (if rank (cdr rank) "")
            (git-bug--bug-time 'edit_time bug))))

(defun git-bug--label-key-lessp (a b)
  "Return non-nil when label sort key A precedes label sort key B.
The edit time orders newest first inside one rank and one sort
text."
  (declare (pure t) (side-effect-free t))
  (cond ((/= (aref a 0) (aref b 0))
         (< (aref a 0) (aref b 0)))
        ((not (equal (aref a 1) (aref b 1)))
         (string-version-lessp (aref a 1) (aref b 1)))
        (t (> (aref a 2) (aref b 2)))))

(defun git-bug--sort-bugs (bugs &optional sort label-order)
  "Return BUGS sorted by SORT, ranking their labels with LABEL-ORDER.
SORT defaults to `git-bug-status-section-sort' and LABEL-ORDER to
`git-bug-status-section-label-order'; an unknown SORT leaves BUGS
in their order."
  (declare (side-effect-free t))
  (let ((sorted (copy-sequence bugs))
        (sort (or sort git-bug-status-section-sort))
        (rules (or label-order git-bug-status-section-label-order)))
    (pcase sort
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
      ('label
       ;; Decorate first, so one key per bug is built once rather than
       ;; once per comparison.
       (mapcar #'cdr
               (sort (mapcar (lambda (bug)
                               (cons (git-bug--label-sort-key bug rules) bug))
                             sorted)
                     (lambda (a b)
                       (git-bug--label-key-lessp (car a) (car b))))))
      ('id
       (sort sorted (lambda (a b)
                      (string-lessp (or (alist-get 'id a) "")
                                    (or (alist-get 'id b) "")))))
      (_ sorted))))

(defun git-bug--displayed-bugs (bugs)
  "Return BUGS after filtering and sorting."
  (declare (side-effect-free t))
  (git-bug--sort-bugs (git-bug--filter-bugs bugs)))

(defun git-bug--check-scope (scope)
  "Signal `git-bug-invalid-argument' unless SCOPE is a bug scope.
Return SCOPE, so a caller can validate before it runs git-bug."
  (declare (side-effect-free t))
  (unless (memq scope '(open closed all))
    (signal 'git-bug-invalid-argument
            (list (format "Invalid bug scope: %S" scope)
                  :value scope)))
  scope)

(defun git-bug--select (bugs scope)
  "Return the BUGS matching SCOPE.
BUGS is a list of bug alists as returned by `git-bug--list'.
SCOPE is one of the symbols `open', `closed' or `all'.  Signal
`git-bug-invalid-argument' for any other value."
  (declare (side-effect-free t))
  (pcase (git-bug--check-scope scope)
    ('all bugs)
    ('open (cl-remove-if-not
            (lambda (bug) (equal (alist-get 'status bug) "open"))
            bugs))
    ('closed (cl-remove-if-not
              (lambda (bug) (equal (alist-get 'status bug) "closed"))
              bugs))))

;;; Data access

(defun git-bug-field (object name)
  "Return the value of OBJECT for NAME, an alist of symbol keys.
NAME is a symbol or a string and compares case-insensitively,
because git-bug spells keys differently in its list and its show
answers.  Return nil when OBJECT has no such key; JSON null and
JSON false both read as nil, so a renderer cannot tell them apart."
  (declare (pure t) (side-effect-free t))
  (let ((needle (downcase (if (symbolp name) (symbol-name name) name))))
    (cdr (cl-find-if
          (lambda (cell)
            (and (consp cell)
                 (symbolp (car cell))
                 (string-equal (downcase (symbol-name (car cell)))
                               needle)))
          object))))

(defvar git-bug--detail-cache (make-hash-table :test #'equal)
  "Cache of bug details keyed by repository, full id and edit time.
Each value is a cons of the fetch time and the detail alist.")

(defconst git-bug--detail-cache-limit 500
  "Maximum number of entries in `git-bug--detail-cache'.")

(defun git-bug--repo-key (repo)
  "Return the cache key of REPO."
  (directory-file-name (expand-file-name repo)))

(defun git-bug--cache-fresh-p (fetch-time)
  "Return non-nil when a detail fetched at FETCH-TIME is still fresh.
`git-bug-detail-ttl' nil keeps every answer; zero keeps none."
  (let ((ttl git-bug-detail-ttl))
    (or (null ttl)
        (< (- (float-time) fetch-time) ttl))))

(defun git-bug--cache-keys (repo id)
  "Return the cache keys of REPO's bug ID.
REPO is a `git-bug--repo-key'; ID is the full id."
  (let (keys)
    (maphash (lambda (key _cell)
               (when (and (equal (nth 0 key) repo)
                          (equal (nth 1 key) id))
                 (push key keys)))
             git-bug--detail-cache)
    keys))

(defun git-bug--cache-lookup (repo id edit-time)
  "Return the freshest cached detail of REPO's ID, or nil.
EDIT-TIME non-nil restricts the answer to that edit time; the
lifetime of an answer comes from `git-bug-detail-ttl'."
  (let (best)
    (dolist (key (git-bug--cache-keys repo id))
      (let ((cell (gethash key git-bug--detail-cache)))
        (when (and (git-bug--cache-fresh-p (car cell))
                   (or (null edit-time)
                       (equal edit-time (nth 2 key)))
                   (or (null best) (> (car cell) (car best))))
          (setq best cell))))
    (cdr best)))

(defun git-bug--cached-detail (repo id)
  "Return the newest cached detail of REPO's ID, however stale."
  (let (best)
    (dolist (key (git-bug--cache-keys repo id))
      (let ((cell (gethash key git-bug--detail-cache)))
        (when (or (null best) (> (car cell) (car best)))
          (setq best cell))))
    (cdr best)))

(defun git-bug--cache-store (repo id edit-time detail)
  "Cache in REPO the answer of bug ID at EDIT-TIME as DETAIL.
Keep one answer per bug, and empty the whole cache at its limit."
  (dolist (key (git-bug--cache-keys repo id))
    (unless (equal edit-time (nth 2 key))
      (remhash key git-bug--detail-cache)))
  (when (>= (hash-table-count git-bug--detail-cache)
            git-bug--detail-cache-limit)
    (clrhash git-bug--detail-cache))
  (puthash (list repo id edit-time) (cons (float-time) detail)
           git-bug--detail-cache))

(defun git-bug--cache-drop (repo id)
  "Remove every cached answer of REPO's ID and return the newest."
  (let ((old (git-bug--cached-detail repo id)))
    (dolist (key (git-bug--cache-keys repo id))
      (remhash key git-bug--detail-cache))
    old))

(defun git-bug--notify (event repo id old new)
  "Report EVENT on REPO's bug ID to the package and its consumers.
Refresh the views of the bug first, so that a consumer sees an
updated display and a failing consumer hook cannot leave them
stale.  OLD and NEW are the details that go away and arrive,
either of which may be nil."
  (let ((notification (list :type 'bug :kind 'show :event event
                            :repo repo :id id :old old :new new)))
    (git-bug--refresh-views notification)
    (run-hook-with-args 'git-bug-change-functions notification)))

(defun git-bug--fetch-detail (repo id)
  "Fetch from REPO the full bug ID as an alist."
  (git-bug--parse-json
   (git-bug--call repo "bug" "show" id "--format" "json")))

(defun git-bug--fetch-and-cache (repo id)
  "Fetch REPO's bug ID and cache the answer without reporting it.
REPO is a `git-bug--repo-key'.  Signal the conditions of
`git-bug--fetch-detail'."
  (let* ((detail (git-bug--fetch-detail repo id))
         (full (or (git-bug-field detail 'id) id)))
    (git-bug--cache-store repo full (git-bug--bug-edit-time detail) detail)
    detail))

(defun git-bug--refresh-detail (repo id event &optional always)
  "Fetch REPO's bug ID, replace its cached answer and report EVENT.
EVENT is `create', `change' or nil.  Report a `create' when the bug
had no cached answer, a `change' when the fetched answer differs
from the cached one, and nothing for nil.  ALWAYS reports EVENT even
without a cached answer, which is what a write wants: the caller
knows that storage changed.  Signal the conditions of
`git-bug--fetch-detail'."
  (let* ((repo (git-bug--repo-key repo))
         (detail (git-bug--fetch-detail repo id))
         (full (or (git-bug-field detail 'id) id))
         (old (git-bug--cached-detail repo full)))
    (git-bug--cache-store repo full (git-bug--bug-edit-time detail) detail)
    (when (or always
              (pcase event
                ('create (null old))
                ('change (and old (not (equal old detail))))
                (_ nil)))
      (git-bug--notify event repo full old detail))
    detail))

(defun git-bug--detail (repo id &optional edit-time force)
  "Return from REPO the full bug ID as an alist.
Unlike the entries returned by `git-bug--list', the result includes
the labels and the comments; comment number zero is the bug
description.  With EDIT-TIME, reuse only an answer cached for that
edit time; without it, any answer `git-bug-detail-ttl' keeps fresh
will do.  FORCE asks git-bug again and reports a changed answer
through `git-bug-change-functions'."
  (let* ((repo (git-bug--repo-key repo))
         (cached (unless force (git-bug--cache-lookup repo id edit-time))))
    (or cached
        (if force
            (git-bug--refresh-detail repo id 'change)
          (git-bug--fetch-and-cache repo id)))))

;;;###autoload
(defun git-bug-get (repo id &optional force)
  "Return from REPO the full bug ID as an alist.
ID is the full id; a short id works as long as git-bug resolves it,
and the answer is cached under the full id anyway.  Unlike
`git-bug-list', the answer carries `labels' and a `comments' list
whose first element is the description.
Reuse a cached answer while `git-bug-detail-ttl' allows it, unless
FORCE is non-nil; then ask git-bug and report a changed answer
through `git-bug-change-functions'.  Signal `git-bug-call-failed'
when git-bug fails, `git-bug-missing-program' when the executable
is absent and `git-bug-invalid-output' when its answer is not JSON."
  (git-bug--detail repo id nil force))

;;;###autoload
(defun git-bug-list (repo &optional filters)
  "Return the bugs of REPO, filtered, sorted and scoped.
REPO is a directory name.  The result keeps the shape of the
`git-bug bug --format json' answers, where `comments' is a count
rather than a list; call `git-bug-get' for one full bug.
FILTERS is a plist, and a nil value keeps the customizable default:

  :scope        `open' by default, or `closed' or `all'
  :label        a label that every returned bug carries
  :author       a name, login or human id the author matches
  :sort         `edit-time', `create-time', `title', `status',
                `label' or `id'
  :label-order  rules ranking bugs for the `label' sort order

Signal `git-bug-call-failed' when git-bug fails,
`git-bug-invalid-output' when its answer is not JSON and
`git-bug-invalid-argument' for an unknown scope, before it runs
git-bug at all."
  (let ((scope (git-bug--check-scope
                (or (plist-get filters :scope)
                    git-bug-status-section-scope)))
        (label (plist-get filters :label))
        (author (plist-get filters :author))
        (sort (plist-get filters :sort))
        (order (plist-get filters :label-order)))
    (git-bug--select
     (git-bug--sort-bugs (git-bug--filter-bugs (git-bug--list repo)
                                               label author)
                         sort order)
     scope)))

;;;###autoload
(defun git-bug-forget (&optional repo id)
  "Drop cached bug details.
With neither REPO nor ID, forget every repository.  With REPO only,
forget every bug of REPO; with REPO and ID, forget that one bug.
ID is a full id, or the `human_id' that a heading shows.
Run `git-bug-change-functions' once per forgotten bug with :event
`invalidate', :old the answer that goes away and :new nil.  An
`invalidate' carries no new answer, so a view of that bug keeps its
text and re-reads storage on its next refresh."
  (let ((key (and repo (git-bug--repo-key repo)))
        pairs)
    (maphash (lambda (entry cell)
               (when (and (or (null key) (equal (nth 0 entry) key))
                          (or (null id)
                              (equal (nth 1 entry) id)
                              (equal id (git-bug-field (cdr cell) 'human_id))))
                 (push (list (nth 0 entry) (nth 1 entry)) pairs)))
             git-bug--detail-cache)
    (dolist (pair (delete-dups pairs))
      (let ((old (git-bug--cache-drop (car pair) (cadr pair))))
        (when old
          (git-bug--notify 'invalidate (car pair) (cadr pair) old nil))))
    nil))

(defun git-bug--set-status (repo id status)
  "Set in REPO the status of bug ID to STATUS.
STATUS is either \"open\" or \"close\", matching the git-bug
command line.  Report the new answer through
`git-bug-change-functions' and return it, so that a caller need not
fetch it again."
  (git-bug--call repo "bug" "status" status id)
  (git-bug--refresh-detail repo id 'change t))

(defun git-bug--markdown-ts-ready-p ()
  "Return non-nil when markdown fontification is available.
That is the case when the builtin `markdown-ts-mode' exists and
both of the tree-sitter grammars it needs, `markdown' and
`markdown-inline', exist."
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
buffer.  Copy the `face' properties of the mode to
`font-lock-face', which refontification does not strip (see
`font-lock-default-unfontify-region').

Return STRING unchanged when the tree-sitter grammars are absent (see
`git-bug--markdown-ts-ready-p') or when the mode signals an error."
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
DETAIL is a bug alist, as `git-bug--detail' returns it."
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
  "Repository of the bug in this buffer.")

(defvar-local git-bug--buffer-id nil
  "Full id of the bug in this buffer.")

(defvar-local git-bug--buffer-human-id nil
  "Short id of the bug in this buffer.")

(defvar-local git-bug--buffer-status nil
  "Status of the bug in this buffer.")

(defvar-local git-bug--buffer-edit-time nil
  "Edit timestamp of the bug in this buffer.")

(defvar-keymap git-bug-mode-map
  :doc "Keymap for `git-bug-mode'."
  :parent special-mode-map
  "q" #'quit-window
  "g" #'revert-buffer
  "w" #'git-bug-copy-id-at-point
  "W" #'git-bug-copy-full-id-at-point
  "C-c r" #'git-bug-copy-ref-at-point
  "x" #'git-bug-toggle-status-in-buffer
  "c" #'git-bug-add-comment-at-point
  "l" #'git-bug-edit-labels-at-point)

(define-derived-mode git-bug-mode special-mode "Git-Bug"
  "Major mode for viewing a single bug.
The buffer reads its text from git-bug rather than from a file, so
\\[revert-buffer] re-reads the bug from storage."
  :interactive nil
  (setq-local buffer-read-only t)
  (setq-local revert-buffer-function #'git-bug--revert-buffer)
  (visual-line-mode 1))

(defun git-bug--render-buffer (detail)
  "Replace the current buffer's text with DETAIL.
Also remember the status, edit time and short id of DETAIL."
  (setq-local git-bug--buffer-status (git-bug-field detail 'status))
  (setq-local git-bug--buffer-edit-time (git-bug--bug-edit-time detail))
  (when-let* ((human (git-bug-field detail 'human_id)))
    (setq-local git-bug--buffer-human-id human))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (git-bug--insert-bug-buffer detail)
    (goto-char (point-min))))

(defun git-bug-refresh-buffer (&optional force)
  "Refresh the current `git-bug-mode' buffer from git-bug.
With FORCE, ignore the cached detail."
  (interactive "P")
  (unless (derived-mode-p 'git-bug-mode)
    (user-error "Not a git-bug buffer"))
  (git-bug--render-buffer
   (git-bug--detail git-bug--buffer-repo
                    git-bug--buffer-id
                    git-bug--buffer-edit-time
                    force)))

(defun git-bug--revert-buffer (&rest _arguments)
  "Re-read the bug of the current buffer from git-bug.
Ignore ARGUMENTS, as `revert-buffer-function' requires.  Bypass
the detail cache, because a revert reaches the storage again."
  (git-bug-refresh-buffer t))

(defun git-bug-toggle-status-in-buffer ()
  "Toggle the status of the bug in the current `git-bug-mode' buffer."
  (interactive)
  (unless (derived-mode-p 'git-bug-mode)
    (user-error "Not a git-bug buffer"))
  ;; The write reports the new answer, which is the one this buffer
  ;; shows; fetching it again would cost a second git-bug call.
  (git-bug--render-buffer
   (git-bug--set-status git-bug--buffer-repo
                        git-bug--buffer-id
                        (if (equal git-bug--buffer-status "open")
                            "close"
                          "open"))))

(defun git-bug--viewer-name (human id)
  "Return the buffer name of a viewer for HUMAN or, failing that, ID."
  (format "*git-bug: %s*" (or human id)))

;;;###autoload
(defun git-bug-buffer (repo id &optional mode)
  "Return a buffer showing REPO's bug ID, without displaying it.
Reuse the buffer of that bug when one is open, and leave it
unselected.  MODE defaults to `git-bug-mode' and must derive from
it.  Signal the conditions of `git-bug-get', before a buffer
exists, and a `user-error' for a MODE that does not derive from
`git-bug-mode', also before a buffer exists."
  (let ((mode (or mode 'git-bug-mode)))
    (unless (provided-mode-derived-p mode 'git-bug-mode)
      (user-error "%S is not a mode derived from `git-bug-mode'" mode))
    (let* ((detail (git-bug-get repo id))
           (human (git-bug-field detail 'human_id))
           (buffer (get-buffer-create (git-bug--viewer-name human id))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'git-bug-mode)
          (funcall mode))
        (setq-local default-directory (file-name-as-directory repo)
                    git-bug--buffer-repo (git-bug--repo-key repo)
                    git-bug--buffer-id (or (git-bug-field detail 'id) id)
                    git-bug--buffer-human-id human)
        (git-bug--render-buffer detail))
      buffer)))

;;;###autoload
(defun git-bug-show (repo id &optional mode)
  "Show REPO's bug ID in a `git-bug-mode' buffer and select it.
MODE defaults to `git-bug-mode'; see `git-bug-buffer' for the
arguments."
  (pop-to-buffer (git-bug-buffer repo id mode)))

(defun git-bug-show-bug (repo bug)
  "Show REPO's BUG in a dedicated `git-bug-mode' buffer.
BUG is a bug alist as `git-bug-list' returns it; use `git-bug-show'
to open a bug by id."
  (git-bug-show repo (git-bug-field bug 'id)))

(defun git-bug-show-bug-at-point ()
  "Show the bug at point in a dedicated buffer."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (git-bug-show-bug (magit-toplevel) bug)
    (user-error "No bug at point")))

(defvar-local git-bug--compose-callback nil
  "Function that receives the composed text on submit.")

(defvar-keymap git-bug-compose-mode-map
  :doc "Keymap for `git-bug-compose-mode'."
  :parent text-mode-map
  "C-c C-c" #'git-bug-compose-submit
  "C-c C-k" #'git-bug-compose-cancel)

(define-derived-mode git-bug-compose-mode text-mode "Git-Bug-Compose"
  "Major mode for composing a git-bug message."
  :interactive nil
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
Git-bug takes the title from the first line of the message, so the
body starts after the blank line that follows it.  Report the new
bug through `git-bug-change-functions'."
  (let ((out (git-bug--call-with-input
              repo (concat (git-bug--clean-title title) "\n\n" body)
              "bug" "new" "--non-interactive" "-F" "-")))
    (let ((id (car (split-string out))))
      (git-bug--refresh-detail repo id 'create)
      id)))

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
         (message "Created bug %s" (git-bug--create-bug repo title body)))))))

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
  "Add to REPO's bug ID the comment BODY.
Report the new answer through `git-bug-change-functions'."
  (git-bug--call-with-input
   repo body "bug" "comment" "new" id "--non-interactive" "-F" "-")
  (git-bug--refresh-detail repo id 'change t))

(defun git-bug--set-labels (repo id labels)
  "Set in REPO the labels of bug ID to LABELS.
Read the current labels from git-bug rather than from the cache,
because the write depends on them, and report the new answer through
`git-bug-change-functions'."
  (let* ((key (git-bug--repo-key repo))
         (detail (git-bug--fetch-and-cache key id))
         (current (alist-get 'labels detail))
         (added (cl-set-difference labels current :test #'equal))
         (removed (cl-set-difference current labels :test #'equal)))
    (when added
      (apply #'git-bug--call key "bug" "label" "new" id added))
    (when removed
      (apply #'git-bug--call key "bug" "label" "rm" id removed))
    (git-bug--refresh-detail key id 'change t)))

(defun git-bug--refresh-views (notification)
  "Refresh the views of the bug that NOTIFICATION reports.
Render the answer the notification carries, so a write costs no
second fetch.  An `invalidate' carries no answer at all, so a view of
that bug keeps its text until its next refresh.  Leave the current
buffer alone: a viewer that is mid-refresh renders itself from the
answer it already fetched."
  (let ((repo (plist-get notification :repo))
        (id (plist-get notification :id))
        (new (plist-get notification :new)))
    (when new
      (dolist (buffer (buffer-list))
        (when (and (not (eq buffer (current-buffer)))
                   (with-current-buffer buffer
                     (and (derived-mode-p 'git-bug-mode)
                          (equal git-bug--buffer-repo repo)
                          (equal git-bug--buffer-id id))))
          (with-current-buffer buffer
            (git-bug--render-buffer new))))
      (git-bug--refresh-after-write repo))))

;;;###autoload
(defun git-bug-add-comment-at-point ()
  "Add a comment to the bug at point."
  (interactive)
  (pcase-let ((`(,repo ,id ,human) (git-bug--current-bug)))
    (git-bug--compose
     (format "Comment on %s" human)
     ""
     (lambda (body)
       (git-bug--add-comment repo id body)))))

;;;###autoload
(defun git-bug-edit-labels-at-point ()
  "Edit the labels of the bug at point."
  (interactive)
  (pcase-let ((`(,repo ,id ,_) (git-bug--current-bug)))
    (let* ((detail (git-bug--detail repo id))
           (current (git-bug--sorted-labels
                     (copy-sequence (alist-get 'labels detail))))
           (value (completing-read-multiple
                   "Labels: " nil nil nil
                   (string-join current ","))))
      (git-bug--set-labels
       repo id
       (cl-remove-if #'string-empty-p
                     (mapcar #'string-trim value))))))

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

(defconst git-bug--heading-columns '(id status title labels replies age)
  "Columns of a bug heading, in display order.")

(defconst git-bug--heading-column-alignment
  '((id . left)
    (status . left)
    (title . left)
    (labels . left)
    (replies . right)
    (age . right))
  "Alignment of each heading column.")

(defun git-bug--heading-cells (bug)
  "Return the heading cells of BUG as an alist of COLUMN to (TEXT FACE).
TEXT is nil for a column without content, such as the labels of an
unlabelled bug."
  (declare (side-effect-free t))
  (let* ((status (or (alist-get 'status bug) "unknown"))
         (labels (git-bug--sorted-labels (alist-get 'labels bug)))
         (replies (git-bug--comment-count bug))
         (age (git-bug--age-string
               (alist-get 'timestamp (alist-get 'edit_time bug)))))
    (list
     (cons 'id (list (or (alist-get 'human_id bug) "") 'magit-hash))
     (cons 'status
           (list status (if (equal status "open") 'success 'magit-dimmed)))
     (cons 'title (list (git-bug--clean-title (alist-get 'title bug))
                        'magit-section-heading))
     (cons 'labels (list (when labels (format "[%s]" (string-join labels ",")))
                         'magit-tag))
     (cons 'replies (list (when (> replies 0) (format "(%d)" replies))
                          'magit-dimmed))
     (cons 'age (list (unless (string-empty-p age) age) 'magit-dimmed)))))

(defun git-bug--heading-widths (bugs)
  "Return an alist of heading column widths for BUGS.
Every column is as wide as its widest cell, so that all headings
line up like the rows of a table.  Columns without any content end
up zero wide and are left out when the headings are rendered."
  (declare (side-effect-free t))
  (let ((cells (mapcar #'git-bug--heading-cells bugs)))
    (mapcar (lambda (column)
              (cons column
                    (cl-loop for row in cells
                             maximize (length (or (car (alist-get column row)) "")))))
            git-bug--heading-columns)))

(defun git-bug--pad-cell (text face width align)
  "Return TEXT fontified with FACE and padded to WIDTH.
A nil FACE leaves TEXT plain.  ALIGN is either the symbol `left' or
`right'.  The padding stays unfontified, so it never carries the
color of the cell."
  (declare (pure t) (side-effect-free t))
  (let* ((body (if face (propertize text 'font-lock-face face) text))
         (padding (max 0 (- width (length text)))))
    (if (eq align 'right)
        (concat (make-string padding ?\s) body)
      (concat body (make-string padding ?\s)))))

(defun git-bug--heading-string (bug widths &optional faces)
  "Return the heading line of BUG, laid out with column WIDTHS.
A nil FACES leaves the line without faces.  WIDTHS is an alist as
`git-bug--heading-widths' returns it.  Cells of a zero-wide column
are left out, so a list of only open bugs spends no room on the
width of \"closed\"."
  (let* ((cells (git-bug--heading-cells bug))
         (columns (cl-remove-if-not (lambda (column)
                                      (> (alist-get column widths) 0))
                                    git-bug--heading-columns))
         (parts (mapcar (lambda (column)
                          (let ((cell (alist-get column cells)))
                            (git-bug--pad-cell
                             (or (car cell) "")
                             (and faces (cadr cell))
                             (alist-get column widths)
                             (alist-get column
                                        git-bug--heading-column-alignment))))
                        columns)))
    (string-trim-right (string-join parts " "))))

;;;###autoload
(defun git-bug-format-bug (bug &optional faces)
  "Return the heading line of BUG as text.
The heading carries the short id, status, title, labels, reply count
and age.  FACES non-nil keeps the Magit faces of the status section;
the default is plain text, for export.  Use
`git-bug-format-bug-list' to line up several bugs in columns."
  (git-bug--heading-string bug (git-bug--heading-widths (list bug)) faces))

;;;###autoload
(defun git-bug-format-bug-list (bugs &optional faces)
  "Return the heading lines of BUGS as text, one per line.
Share the column widths of the whole list, so the cells of every
line start at the same offset.  FACES non-nil keeps the faces of the
status section; the default is plain text."
  (let ((widths (git-bug--heading-widths bugs)))
    (mapconcat (lambda (bug) (git-bug--heading-string bug widths faces))
               bugs "\n")))

(defun git-bug--refresh-current-status ()
  "Refresh the Magit status buffer for the current context."
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
                 '("edit-time" "create-time" "title" "status" "label" "id")
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

(defun git-bug--insert-bug (repo bug widths)
  "Insert REPO's BUG as a collapsed `git-bug-bug-section'.
WIDTHS are the shared column widths of the surrounding list, see
`git-bug--heading-widths'."
  (magit-insert-section (git-bug-bug-section bug 'hide)
    (let ((bug-id (alist-get 'id bug)))
      ;; Note the `font-lock-face' property, not `face': font-lock
      ;; refontification strips `face', leaving the ids unfontified.
      (magit-insert-heading (git-bug--heading-string bug widths t))
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

(defun git-bug--insert-group (repo label bugs widths)
  "Insert for REPO a status group named LABEL with BUGS.
WIDTHS are the shared column widths of the whole bug list."
  (magit-insert-section (git-bug-status-group-section)
    (magit-insert-heading (format "%s (%d)" label (length bugs)))
    (dolist (bug bugs)
      (git-bug--insert-bug repo bug widths))
    (insert ?\n)))

(defun git-bug--insert-bugs (repo bugs)
  "Insert for REPO the Bugs section for BUGS.
Handle a nil BUGS list when `git-bug-status-section-show-empty' is
non-nil."
  (let* ((scope git-bug-status-section-scope)
         (displayed (and bugs (git-bug--displayed-bugs bugs)))
         (shown (git-bug--select displayed scope))
         (widths (git-bug--heading-widths shown)))
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
                (git-bug--insert-group repo (car group) group-bugs widths)))))
         (t
          (dolist (bug shown)
            (git-bug--insert-bug repo bug widths))))
        (insert ?\n)))))

;;;###autoload
(defun git-bug-insert-status-bugs ()
  "Insert a section listing the git-bug bugs of the repository.
Use it in `magit-status-sections-hook'.  `git-bug-status-section-scope'
controls which bugs the section lists; the heading always shows the
number of listed bugs over the number of all bugs."
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
  "Toggle the open/closed status of the bug at point.
The status section and any viewer of the bug refresh themselves,
then `git-bug-change-functions' runs."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (git-bug--set-status (magit-toplevel)
                           (alist-get 'id bug)
                           (if (equal (alist-get 'status bug) "open")
                               "close"
                             "open"))
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
