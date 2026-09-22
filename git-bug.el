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
;; Package-Requires: ((emacs "30.1") (magit "4.0.0"))
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
;; description and comments.  On a bug heading, `RET' copies the short
;; id and `x' flips the open/closed status.
;;
;; Which bugs are listed is controlled by `git-bug-status-section-scope'.
;; When this package is built with Nix, `git-bug-program' is rewritten
;; to the absolute store path of the git-bug binary, so nothing has to
;; be present on `exec-path'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'magit)
(require 'subr-x)

(defgroup git-bug nil
  "Git-bug sections for Magit."
  :group 'tools
  :prefix "git-bug-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/emacs-git-bug"))

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

(defvar-keymap git-bug-bug-section-map
  :doc "Keymap for `git-bug-bug-section' headings."
  "RET" #'git-bug-copy-id-at-point
  "x"   #'git-bug-toggle-status-at-point)

(defclass git-bug-bugs-section (magit-section) ()
  "Class for the section listing the bugs of a repository.")

(defclass git-bug-bug-section (magit-section)
  ((keymap :initform 'git-bug-bug-section-map))
  "Class for a single bug.")

(defun git-bug--call (repo &rest args)
  "Run git-bug with ARGS in REPO and return its standard output.
Standard error goes to a temporary file: the split-destination
form of `call-process' only accepts file names for it, and
git-bug prints progress noise there anyway.  Signal an error when
git-bug exits with a non-zero status."
  (let ((stderr (make-temp-file "git-bug-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let* ((default-directory (file-name-as-directory repo))
                 (exit (apply #'call-process git-bug-program nil
                              (list t stderr) nil args)))
            (unless (eq exit 0)
              (let ((err (string-trim (git-bug--read-file stderr))))
                (error "Git-bug %s failed: %s"
                       (string-join args " ")
                       (if (string-empty-p err)
                           (string-trim (buffer-string))
                         err))))
            (buffer-string)))
      (delete-file stderr))))

(defun git-bug--read-file (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun git-bug--parse-json (string)
  "Parse JSON STRING into Lisp data.
Objects become alists keyed by symbols, arrays become lists and
JSON null becomes nil."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun git-bug--list (repo)
  "Return all bugs in REPO as a list of alists.
Return nil when REPO contains no bugs.  When git-bug fails, show
the error in the echo area and return nil, so that a broken
tracker never breaks `magit-status'."
  (condition-case err
      (let ((out (git-bug--call repo "bug" "--format" "json")))
        (unless (string-blank-p out)
          (git-bug--parse-json out)))
    (error (message "Git-bug: %s" (error-message-string err)) nil)))

(defun git-bug--select (bugs scope)
  "Return the BUGS matching SCOPE.
BUGS is a list of bug alists as returned by `git-bug--list'.
SCOPE is one of the symbols `open', `closed' or `all'."
  (pcase scope
    ('all bugs)
    ('open (cl-remove-if-not
            (lambda (bug) (equal (alist-get 'status bug) "open"))
            bugs))
    ('closed (cl-remove-if-not
              (lambda (bug) (equal (alist-get 'status bug) "closed"))
              bugs))
    (_ (error "Invalid bug scope: %S" scope))))

(defun git-bug--detail (repo id)
  "Return the full bug ID in REPO as an alist.
Unlike the entries returned by `git-bug--list', the result includes
the labels and the comments; comment number zero is the bug
description."
  (git-bug--parse-json
   (git-bug--call repo "bug" "show" id "--format" "json")))

(defun git-bug--set-status (repo id status)
  "Set the status of bug ID in REPO to STATUS.
STATUS is either \"open\" or \"close\", matching the git-bug
command line."
  (git-bug--call repo "bug" "status" status id))

(defun git-bug--insert-detail (detail)
  "Insert the labels, description and comments of DETAIL.
DETAIL is a bug alist as returned by `git-bug--detail'."
  (when-let* ((labels (alist-get 'labels detail)))
    (insert (propertize (format "Labels: %s" (string-join labels ", "))
                        'font-lock-face 'magit-tag))
    (insert "\n"))
  (let ((comments (alist-get 'comments detail)))
    ;; Comment number zero is the bug description.
    (when-let* ((body (car comments)))
      (insert (alist-get 'message body) "\n"))
    (cl-loop
     for comment in (cdr comments)
     for n from 1
     for author = (alist-get 'author comment)
     for name = (alist-get 'name author)
     do (insert "\n")
        (insert (propertize (format "#%d " n) 'font-lock-face 'magit-dimmed)
                (propertize (or name (alist-get 'human_id author))
                            'font-lock-face
                            (if name 'magit-dimmed 'magit-hash))
                (propertize ":" 'font-lock-face 'magit-dimmed))
        (insert "\n")
        (insert (alist-get 'message comment) "\n"))))

(defun git-bug--insert-bug (repo bug)
  "Insert BUG from REPO as a collapsed `git-bug-bug-section'."
  (magit-insert-section (git-bug-bug-section bug 'hide)
    (let ((id (alist-get 'human_id bug))
          (status (alist-get 'status bug)))
      ;; Note the `font-lock-face' property, not `face': font-lock
      ;; refontification strips `face', leaving the ids unfontified.
      (magit-insert-heading
       (format "%s %s %s"
               (propertize id 'font-lock-face 'magit-hash)
               (propertize (format "%-6s" status)
                           'font-lock-face (if (equal status "open")
                                               'success
                                             'magit-dimmed))
               (propertize (alist-get 'title bug)
                           'font-lock-face 'magit-section-heading)))
      (when-let* ((detail (condition-case nil
                              (git-bug--detail repo id)
                            (error nil))))
        (git-bug--insert-detail detail)))))

;;;###autoload
(defun git-bug-insert-status-bugs ()
  "Insert a section listing the git-bug bugs of the repository.
Meant for `magit-status-sections-hook'.  Which bugs are listed is
controlled by `git-bug-status-section-scope'; the heading always
shows the number of listed bugs over the number of all bugs."
  (when-let* ((repo (magit-toplevel))
              (bugs (git-bug--list repo)))
    (let ((shown (git-bug--select bugs git-bug-status-section-scope)))
      (magit-insert-section (git-bug-bugs-section)
        (magit-insert-heading
         (format "Bugs (%d/%d)" (length shown) (length bugs)))
        (dolist (bug shown)
          (git-bug--insert-bug repo bug))
        (insert ?\n)))))

;;;###autoload
(defun git-bug-copy-id-at-point ()
  "Copy the short id of the bug at point to the kill ring."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (let ((id (alist-get 'human_id bug)))
        (kill-new id)
        (message "Copied bug id %s" id))
    (user-error "No bug at point")))

;;;###autoload
(defun git-bug-toggle-status-at-point ()
  "Toggle the open/closed status of the bug at point."
  (interactive)
  (if-let* ((bug (magit-section-value-if 'git-bug-bug-section)))
      (progn
        (git-bug--set-status (magit-toplevel)
                             (alist-get 'human_id bug)
                             (if (equal (alist-get 'status bug) "open")
                                 "close"
                               "open"))
        (when (derived-mode-p 'magit-mode)
          (magit-refresh)))
    (user-error "No bug at point")))

(provide 'git-bug)

;;; git-bug.el ends here
