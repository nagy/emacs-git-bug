;;; git-bug-tests.el --- Tests for git-bug.el -*- lexical-binding: t -*-

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

;;; Commentary:

;; End-to-end tests for git-bug.el.  Every test drives the real
;; git-bug binary inside a throwaway git repository, so the suite
;; exercises the command-line interface as well as the parsing and
;; rendering code.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'git-bug)

(defun git-bug-tests--git (&rest args)
  "Run git with ARGS in `default-directory'."
  (unless (zerop (apply #'call-process "git" nil nil nil args))
    (error "Git %s failed" (string-join args " "))))

(defmacro git-bug-tests--with-repo (repo &rest body)
  "Run BODY with REPO bound to a fresh repository with git-bug initialized."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((,repo (file-name-as-directory
                  (make-temp-file "git-bug-tests" t)))
          (process-environment
           (append (list (concat "HOME=" ,repo) "GIT_CONFIG_NOSYSTEM=1")
                   process-environment))
          (default-directory ,repo))
     (unwind-protect
         (progn
           (git-bug-tests--git "init" "--quiet")
           (git-bug-tests--git "config" "user.name" "Test User")
           (git-bug-tests--git "config" "user.email" "test@example.com")
           (git-bug--call ,repo "user" "new" "--non-interactive"
                          "--name" "Test User" "--email" "test@example.com")
           ,@body)
       (delete-directory ,repo t))))

(defun git-bug-tests--new-bug (repo title &optional description)
  "Create a bug in REPO with TITLE and return its short id.
DESCRIPTION is the bug body; default to a plain-text one."
  (let ((file (make-temp-file "git-bug-tests-body")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert title "\n\n" (or description
                                     "Problem.  The frobnicator segfaults.\n"
                                     "Decision.  Guard empty input.\n")))
          (let ((out (git-bug--call repo
                                    "bug" "new" "--non-interactive"
                                    "-F" file)))
            (car (split-string out))))
      (delete-file file))))

(ert-deftest git-bug-tests-list-empty-repo ()
  "An empty repository yields no bugs."
  (git-bug-tests--with-repo repo
    (should (null (git-bug--list repo)))))

(ert-deftest git-bug-tests-new-bug-is-listed ()
  "A freshly created bug shows up with title and status."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (should (string-match-p "\\`[[:xdigit:]]\\{7\\}\\'" id))
      (let ((bugs (git-bug--list repo)))
        (should (= (length bugs) 1))
        (let ((bug (car bugs)))
          (should (equal (alist-get 'human_id bug) id))
          (should (equal (alist-get 'title bug) "Broken frobnicator"))
          (should (equal (alist-get 'status bug) "open")))))))

(ert-deftest git-bug-tests-select-scope ()
  "Scope filtering keeps exactly the requested statuses."
  (let ((bugs '(((status . "open"))
                ((status . "closed")))))
    (should (= (length (git-bug--select bugs 'all)) 2))
    (should (= (length (git-bug--select bugs 'open)) 1))
    (should (= (length (git-bug--select bugs 'closed)) 1))
    (should (equal (alist-get 'status (car (git-bug--select bugs 'closed)))
                   "closed"))))

(ert-deftest git-bug-tests-toggle-status ()
  "Closing a bug moves it out of the open scope."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (git-bug--set-status repo id "close")
      (let ((bugs (git-bug--list repo)))
        (should (equal (alist-get 'status (car bugs)) "closed"))
        (should (null (git-bug--select bugs 'open)))
        (should (= (length (git-bug--select bugs 'closed)) 1)))
      (git-bug--set-status repo id "open")
      (should (equal (alist-get 'status (car (git-bug--list repo))) "open")))))

(ert-deftest git-bug-tests-detail ()
  "The detail view carries labels, description and comments."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (git-bug--call repo "bug" "label" "new" id "priority:P2")
      (git-bug--call repo "bug" "comment" "new" id
                     "--non-interactive" "-m" "A comment body.")
      (let* ((detail (git-bug--detail repo id))
             (comments (alist-get 'comments detail)))
        (should (equal (alist-get 'labels detail) '("priority:P2")))
        (should (= (length comments) 2))
        ;; Comment number zero is the description.
        (should (string-match-p "Problem\\." (alist-get 'message (car comments))))
        (should (equal (alist-get 'message (cadr comments))
                       "A comment body."))))))

(ert-deftest git-bug-tests-insert-status-bugs ()
  "The status section renders headings and hidden details."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (git-bug--call repo "bug" "label" "new" id "priority:P2")
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (let ((text (buffer-string)))
          (should (string-match-p "Bugs (1/1)" text))
          (should (string-match-p "Broken frobnicator" text))
          (should (string-match-p "Labels: priority:P2" text))
          (should (string-match-p "Problem\\." text)))))))

(ert-deftest git-bug-tests-insert-status-faces ()
  "The bug id is fontified and survives font-lock refontification."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward id)
        (let ((start (match-beginning 0)))
          (should (eq (get-text-property start 'font-lock-face) 'magit-hash))
          ;; `face' would be stripped by `font-lock', so it must not be used.
          (should (null (get-text-property start 'face)))
          (font-lock-mode 1)
          (font-lock-ensure)
          (should (eq (get-text-property start 'font-lock-face) 'magit-hash)))))))

(ert-deftest git-bug-tests-markdown-ready-p ()
  "Grammar availability follows the boolean, not the DETAIL data."
  (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
            ((symbol-function 'treesit-language-available-p)
             (lambda (&rest _) '(t))))
    (should (git-bug--markdown-ts-ready-p)))
  (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
            ((symbol-function 'treesit-language-available-p)
             (lambda (&rest _) '(nil not-found "missing"))))
    (should-not (git-bug--markdown-ts-ready-p))))

(ert-deftest git-bug-tests-insert-markdown-fontification ()
  "Bug bodies are fontified as Markdown when the grammars exist."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator"
                           "Text with **bold** word.\n")
    (with-temp-buffer
      (git-bug-insert-status-bugs)
      (goto-char (point-min))
      (search-forward "bold")
      (let ((start (match-beginning 0)))
        (should (memq 'markdown-ts-bold
                      (ensure-list (get-text-property start 'font-lock-face))))
        ;; Markup symbols are hidden, their contents are not.
        (should (eq (get-text-property (1- start) 'invisible) t))
        (should (null (get-text-property start 'invisible)))))))

(ert-deftest git-bug-tests-insert-status-bugs-scope ()
  "The scope customizations controls which bugs are rendered."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (git-bug--set-status repo id "close")
      (let ((git-bug-status-section-scope 'open))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (should (string-match-p "Bugs (0/1)" (buffer-string)))))
      (let ((git-bug-status-section-scope 'closed))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (should (string-match-p "Bugs (1/1)" (buffer-string))))))))

(ert-deftest git-bug-tests-copy-id-at-point ()
  "The copy command grabs the short id from the section at point."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward id)
        (goto-char (match-beginning 0))
        (git-bug-copy-id-at-point)
        (should (equal (car kill-ring) id))))))

(ert-deftest git-bug-tests-toggle-status-at-point ()
  "The toggle command flips the status of the section at point."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug-tests--new-bug repo "Broken frobnicator")))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward id)
        (goto-char (match-beginning 0))
        (git-bug-toggle-status-at-point))
      (should (equal (alist-get 'status (car (git-bug--list repo)))
                     "closed")))))

(ert-deftest git-bug-tests-broken-tracker-is-silent ()
  "A failing git-bug never breaks the status buffer."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let ((git-bug-program "false"))
      (should (null (git-bug--list repo)))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (should (string-empty-p (buffer-string)))))))

(provide 'git-bug-tests)

;;; git-bug-tests.el ends here
