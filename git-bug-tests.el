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

(ert-deftest git-bug-tests-empty-initialized-repo ()
  "An initialized repository shows an explicit empty section."
  (git-bug-tests--with-repo repo
    (with-temp-buffer
      (git-bug-insert-status-bugs)
      (let ((text (buffer-string)))
        (should (string-match-p "Bugs (0/0)" text))
        (should (string-match-p "No bugs\\." text))))
    (let ((git-bug-status-section-show-empty nil))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (should (string-empty-p (buffer-string)))))))

(ert-deftest git-bug-tests-create-bug ()
  "The package can create a bug through stdin."
  (git-bug-tests--with-repo repo
    (let ((id (git-bug--create-bug repo "Created from Emacs" "Body text.\n")))
      (should (string-match-p "\\`[[:xdigit:]]\\{7\\}\\'" id))
      (let* ((bug (car (git-bug--list repo)))
             (detail (git-bug--detail repo (alist-get 'id bug))))
        (should (equal (alist-get 'title bug) "Created from Emacs"))
        (should (string-match-p
                 "Body text"
                 (alist-get 'message
                            (car (alist-get 'comments detail)))))))))

(ert-deftest git-bug-tests-compose-submit ()
  "A compose buffer passes its text to the callback and closes."
  (let ((received nil)
        (buffer (generate-new-buffer " *git-bug compose test*")))
    (unwind-protect
        (with-current-buffer buffer
          (git-bug-compose-mode)
          (insert "hello")
          (setq-local git-bug--compose-callback
                      (lambda (text) (setq received text)))
          (git-bug-compose-submit))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (should (equal received "hello")))
  (with-temp-buffer
    (git-bug-compose-mode)
    (should-error (git-bug-compose-submit) :type 'user-error)))

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

(ert-deftest git-bug-tests-heading-and-label-cleanup ()
  "Titles stay on one line and labels render in stable order."
  (should (equal (git-bug--clean-title "One\nTwo\r\nThree") "One Two Three"))
  (should (equal (git-bug--sorted-labels '("z" "a" "m")) '("a" "m" "z")))
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let ((bug (car (git-bug--list repo))))
      (setf (alist-get 'title bug) "One\nTwo")
      (setf (alist-get 'labels bug) '("z" "a"))
      (cl-letf (((symbol-function 'git-bug--list)
                 (lambda (_repo) (list bug)))
                ((symbol-function 'git-bug--detail)
                 (lambda (&rest _)
                   '((labels . ("z" "a"))
                     (comments . (((message . "Body"))))))))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (should (string-match-p "One Two" (buffer-string)))
          (should-not (string-match-p "One\nTwo" (buffer-string)))
          (goto-char (point-min))
          (search-forward "One Two")
          (goto-char (match-beginning 0))
          (magit-section-show (magit-current-section))
          (should (string-match-p "Labels: a, z" (buffer-string))))))))

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

(ert-deftest git-bug-tests-add-comment ()
  "Comments go through stdin and appear in the detail."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let* ((bug (car (git-bug--list repo)))
           (full (alist-get 'id bug)))
      (git-bug--add-comment repo full "A new comment.\n")
      (let* ((detail (git-bug--detail repo full))
             (comments (alist-get 'comments detail)))
        (should (= (length comments) 2))
        (should (equal (alist-get 'message (car (last comments)))
                       "A new comment."))))))

(ert-deftest git-bug-tests-set-labels ()
  "Setting labels adds and removes the difference."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let* ((bug (car (git-bug--list repo)))
           (full (alist-get 'id bug)))
      (git-bug--set-labels repo full '("a" "b"))
      (should (equal (git-bug--sorted-labels
                      (alist-get 'labels (git-bug--detail repo full)))
                     '("a" "b")))
      (git-bug--set-labels repo full '("b" "c"))
      (should (equal (git-bug--sorted-labels
                      (alist-get 'labels (git-bug--detail repo full)))
                     '("b" "c"))))))

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

(ert-deftest git-bug-tests-fontify-unknown-code-language ()
  "A fenced block without its grammar does not stop Markdown faces."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (let* ((text "Text with **bold** word.\n\n```python\nprint(1)\n```\n")
         (out (git-bug--fontify-markdown text))
         (pos (string-match "bold" out)))
    (should (memq 'markdown-ts-bold
                  (ensure-list (get-text-property pos 'font-lock-face out))))))

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
          ;; Details load only after expansion.
          (should-not (string-match-p "Labels: priority:P2" text))
          (goto-char (point-min))
          (search-forward "Broken frobnicator")
          (goto-char (match-beginning 0))
          (magit-section-show (magit-current-section)))
        (let ((text (buffer-string)))
          (should (string-match-p "Labels: priority:P2" text))
          (should (string-match-p "Problem\\." text)))))))

(ert-deftest git-bug-tests-details-load-lazily ()
  "A collapsed bug section does not shell out until expansion."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let ((calls 0))
      (cl-letf (((symbol-function 'git-bug--detail)
                 (lambda (&rest _)
                   (cl-incf calls)
                   nil)))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (should (= calls 0))
          (goto-char (point-min))
          (search-forward "Broken frobnicator")
          (goto-char (match-beginning 0))
          (magit-section-show (magit-current-section))
          (should (= calls 1)))))))

(ert-deftest git-bug-tests-cli-calls-use-full-id ()
  "Detail and status commands receive the full id, not the short id."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Broken frobnicator"))
           (bug (car (git-bug--list repo)))
           (full (alist-get 'id bug))
           (seen-detail nil)
           (seen-status nil))
      (cl-letf (((symbol-function 'git-bug--detail)
                 (lambda (_repo id &rest _)
                   (setq seen-detail id)
                   nil)))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (goto-char (point-min))
          (search-forward short)
          (goto-char (match-beginning 0))
          (magit-section-show (magit-current-section))))
      (should (equal seen-detail full))
      (cl-letf (((symbol-function 'git-bug--set-status)
                 (lambda (_repo id _status)
                   (setq seen-status id))))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (goto-char (point-min))
          (search-forward short)
          (goto-char (match-beginning 0))
          (git-bug-toggle-status-at-point)))
      (should (equal seen-status full)))))

(ert-deftest git-bug-tests-detail-author-fallback ()
  "Missing author data renders a placeholder, not an error."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (cl-letf (((symbol-function 'git-bug--detail)
               (lambda (&rest _)
                 '((comments . (((author . nil) (message . "Description"))
                                ((author . nil) (message . "Reply"))))))))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward "Broken frobnicator")
        (goto-char (match-beginning 0))
        (magit-section-show (magit-current-section))
        (should (string-match-p "#1 unknown:" (buffer-string)))))))

(ert-deftest git-bug-tests-detail-error-visible ()
  "A failed detail fetch tells the user instead of staying blank."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (cl-letf (((symbol-function 'git-bug--detail)
               (lambda (&rest _) (error "boom"))))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward "Broken frobnicator")
        (goto-char (match-beginning 0))
        (magit-section-show (magit-current-section))
        (should (string-match-p "Details unavailable: boom"
                                (buffer-string)))))))

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

(ert-deftest git-bug-tests-markdown-options-sandboxed ()
  "Untrusted bodies cannot enable images, folding or editing helpers."
  (let (seen)
    (cl-letf (((symbol-function 'git-bug--markdown-ts-ready-p)
               (lambda () t))
              ((symbol-function 'font-lock-ensure) #'ignore)
              ((symbol-function 'markdown-ts-mode)
               (lambda ()
                 (setq seen (list markdown-ts-hide-markup
                                  markdown-ts-fontify-code-blocks-natively
                                  markdown-ts-inline-images
                                  markdown-ts-display-remote-inline-images
                                  markdown-ts-default-folding
                                  markdown-ts-enable-code-block-context-mode
                                  markdown-ts-enable-table-mode)))))
      (git-bug--fontify-markdown "text"))
    (should (equal seen '(t nil nil nil show-all nil nil)))))

(ert-deftest git-bug-tests-insert-markdown-fontification ()
  "Bug bodies are fontified as Markdown when the grammars exist."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator"
                           "Text with **bold** word.\n")
    (with-temp-buffer
      (git-bug-insert-status-bugs)
      (goto-char (point-min))
      (search-forward "Broken frobnicator")
      (goto-char (match-beginning 0))
      (magit-section-show (magit-current-section))
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

(ert-deftest git-bug-tests-markdown-link-keeps-action ()
  "Markdown links stay clickable after property copying."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (let* ((out (git-bug--fontify-markdown "[link](https://example.com)\n"))
         (pos (string-match "link" out)))
    (should (get-text-property pos 'action out))
    (should (equal (get-text-property pos 'help-echo out)
                   "https://example.com"))))

(ert-deftest git-bug-tests-show-bug-buffer ()
  "The dedicated buffer renders a bug and toggles its status."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug
                   repo "Broken frobnicator" "Body with **bold** text.\n"))
           (bug (car (git-bug--list repo))))
      (unwind-protect
          (progn
            (git-bug-show-bug repo bug)
            (let ((buffer (get-buffer (format "*git-bug: %s*" short))))
              (should buffer)
              (with-current-buffer buffer
                (should (derived-mode-p 'git-bug-mode))
                (should buffer-read-only)
                (should (string-match-p "Broken frobnicator" (buffer-string)))
                (should (string-match-p "Author: Test User" (buffer-string)))
                (should (string-match-p "Body with" (buffer-string)))
                (git-bug-toggle-status-in-buffer)
                (should (string-match-p "closed" (buffer-string))))))
        (when-let* ((buffer (get-buffer (format "*git-bug: %s*" short))))
          (kill-buffer buffer)))
      (should (equal (alist-get 'status (car (git-bug--list repo)))
                     "closed")))))

(ert-deftest git-bug-tests-bug-section-keys ()
  "Bug headings expose view, copy, toggle, comment and label keys."
  (should (eq (lookup-key git-bug-bug-section-map (kbd "RET"))
              #'git-bug-show-bug-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "w"))
              #'git-bug-copy-id-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "x"))
              #'git-bug-toggle-status-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "c"))
              #'git-bug-add-comment-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "l"))
              #'git-bug-edit-labels-at-point))
  (should (eq (lookup-key git-bug-mode-map (kbd "c"))
              #'git-bug-add-comment-at-point))
  (should (eq (lookup-key git-bug-mode-map (kbd "l"))
              #'git-bug-edit-labels-at-point)))

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

(ert-deftest git-bug-tests-broken-tracker-visible ()
  "A failing git-bug renders an unavailable section, not a broken status."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let ((git-bug-program "false"))
      (should-error (git-bug--list repo))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (let ((text (buffer-string)))
          (should (string-match-p "Bugs (unavailable)" text))
          (should (string-match-p "Git-bug failed" text))))
      (let ((git-bug-status-section-show-errors nil))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (should (string-empty-p (buffer-string))))))))

(ert-deftest git-bug-tests-unrelated-repo-is-silent ()
  "A repository without git-bug state never invokes git-bug."
  (let* ((repo (file-name-as-directory
                (make-temp-file "git-bug-tests" t)))
         (default-directory repo)
         (called nil))
    (unwind-protect
        (progn
          (git-bug-tests--git "init" "--quiet")
          (cl-letf (((symbol-function 'git-bug--call)
                     (lambda (&rest _)
                       (setq called t)
                       "[]")))
            (with-temp-buffer
              (git-bug-insert-status-bugs)
              (should (string-empty-p (buffer-string)))))
          (should-not called))
      (delete-directory repo t))))

(provide 'git-bug-tests)

;;; git-bug-tests.el ends here
