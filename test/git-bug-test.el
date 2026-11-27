;;; git-bug-test.el --- Tests for git-bug.el -*- lexical-binding: t -*-

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
  "Bind REPO to a fresh repository with git-bug initialized, then run BODY."
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

(defun git-bug-tests--heading-line (title)
  "Return the heading line that mentions TITLE, without properties."
  (save-excursion
    (goto-char (point-min))
    (search-forward title)
    (buffer-substring-no-properties (line-beginning-position)
                                    (line-end-position))))

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

(ert-deftest git-bug-tests-heading-metadata ()
  "Headings carry sorted labels, reply count and age."
  (should (= (git-bug--comment-count '((comments . 3))) 2))
  (should (= (git-bug--comment-count '((comments . 1))) 0))
  (should (equal (git-bug--age-string nil) ""))
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Broken frobnicator")
    (let ((bug (car (git-bug--list repo))))
      (setf (alist-get 'labels bug) '("b" "a"))
      (setf (alist-get 'comments bug) 3)
      (setf (alist-get 'edit_time bug)
            `((timestamp . ,(truncate (float-time)))))
      (cl-letf (((symbol-function 'git-bug--list)
                 (lambda (_repo) (list bug)))
                ((symbol-function 'git-bug--detail)
                 (lambda (&rest _) nil)))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (let ((text (buffer-string)))
            (should (string-match-p "\\[a,b\\]" text))
            (should (string-match-p "(2)" text))
            (should (string-match-p "now" text))))))))

(ert-deftest git-bug-tests-heading-columns-align ()
  "Labels and ages line up in their own columns."
  (git-bug-tests--with-repo repo
    (let ((short (git-bug-tests--new-bug repo "Short"))
          (long (git-bug-tests--new-bug repo "A considerably longer title")))
      (git-bug--call repo "bug" "label" "new" short "ui")
      (git-bug--call repo "bug" "label" "new" long "core")
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (let ((short-line (git-bug-tests--heading-line "Short"))
              (long-line (git-bug-tests--heading-line
                          "A considerably longer title")))
          (should (string-match-p "\\[ui\\]" short-line))
          (should (string-match-p "\\[core\\]" long-line))
          ;; The labels and the age columns start at the same offset,
          ;; however much the titles differ in length.
          (should (= (string-match "\\[" short-line)
                     (string-match "\\[" long-line)))
          (should (= (string-match "now" short-line)
                     (string-match "now" long-line))))))))

(ert-deftest git-bug-tests-heading-status-column-fits ()
  "The status column is only as wide as the statuses that appear."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Alpha")
    (let ((closed (git-bug-tests--new-bug repo "Bravo")))
      (git-bug--set-status repo closed "close")
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        ;; Only open bugs are listed, so "open" needs no padding.
        (should (string-match-p "open Alpha now\\'"
                                (git-bug-tests--heading-line "Alpha"))))
      (let ((git-bug-status-section-scope 'all))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (let ((open-line (git-bug-tests--heading-line "Alpha"))
                (closed-line (git-bug-tests--heading-line "Bravo")))
            ;; "closed" sets the width, so "open" gets two spaces of
            ;; padding plus the separator before the title.
            (should (string-match-p "open   Alpha now\\'" open-line))
            (should (string-match-p "closed Bravo now\\'" closed-line))
            (should (= (string-match "Alpha" open-line)
                       (string-match "Bravo" closed-line)))))))))

(defun git-bug-tests--fake-bug (human title status labels replies age)
  "Return a bug list for the layout tests.
HUMAN is the short id, TITLE the heading title, STATUS either
\"open\" or \"closed\", LABELS the label list, REPLIES the number
of replies and AGE the edit age in seconds."
  (let ((edited (- (float-time) age)))
    `((id . ,(concat human (make-string 33 ?0)))
      (human_id . ,human)
      (title . ,title)
      (status . ,status)
      (labels . ,labels)
      ;; Git-bug counts the description as comment zero.
      (comments . ,(1+ replies))
      (edit_time . ((timestamp . ,edited)))
      (create_time . ((timestamp . ,edited))))))

(defconst git-bug-tests--layout-mixed
  (list (git-bug-tests--fake-bug "1a2b3c4" "Short" "open" '("ui") 2 120)
        (git-bug-tests--fake-bug "5d6e7f8" "A considerably longer bug title"
                                 "closed" '("core" "urgent") 0 90000)
        (git-bug-tests--fake-bug "9a0b1c2" "Medium" "open" nil 1 4000)
        (git-bug-tests--fake-bug "3d4e5f6" "Same width" "open" '("docs") 0 30))
  "Bugs of mixed status, title length, labels and ages.")

(defconst git-bug-tests--layout-open
  (list (git-bug-tests--fake-bug "1a2b3c4" "Short" "open" nil 0 90)
        (git-bug-tests--fake-bug "5d6e7f8" "A considerably longer bug title"
                                 "open" nil 0 7200)
        (git-bug-tests--fake-bug "9a0b1c2" "Medium" "open" nil 0 30))
  "Only open bugs, with no labels and no replies.")

(defconst git-bug-tests--layout-closed
  (list (git-bug-tests--fake-bug "1a2b3c4" "Fixed thing" "closed"
                                 '("fixed") 1 (* 86400 40))
        (git-bug-tests--fake-bug "5d6e7f8" "Wontfix" "closed"
                                 '("wontfix") 0 (* 86400 3)))
  "Only closed bugs.")

(defconst git-bug-tests--layout-scenarios
  (list (list "open" 'open git-bug-tests--layout-open nil)
        (list "closed" 'closed git-bug-tests--layout-closed nil)
        (list "mixed" 'open git-bug-tests--layout-mixed nil)
        (list "all" 'all git-bug-tests--layout-mixed nil)
        (list "all, grouped" 'all git-bug-tests--layout-mixed t))
  "Layout scenarios, as (NAME SCOPE BUGS GROUPED) lists.
GROUPED turns on `git-bug-status-section-group-by-status'.")

(defun git-bug-tests--layout-rows (bugs)
  "Render BUGS and return their heading rows as (BUG . LINE) pairs.
Lines that are not headings, such as section headings and group
headings, are left out."
  (with-temp-buffer
    (git-bug--insert-bugs "/nonexistent/" bugs)
    (let (rows)
      (dolist (line (split-string (buffer-string) "\n"))
        (when (string-match "\\`\\([[:xdigit:]]\\{7\\}\\) " line)
          (let ((id (match-string 1 line)))
            (when-let* ((bug (cl-find-if
                              (lambda (bug)
                                (equal (alist-get 'human_id bug) id))
                              bugs)))
              (push (cons bug line) rows)))))
      (nreverse rows))))

(defun git-bug-tests--should-align (scenario what offsets)
  "Fail unless the SCENARIO puts every WHAT column at one place.
OFFSETS are the column positions to compare."
  (unless (< (length (delete-dups (copy-sequence offsets))) 2)
    (error "%s: %s out of line: %S" scenario what offsets)))

(ert-deftest git-bug-tests-heading-columns-align-scenarios ()
  "Every heading column lines up, whatever the shape of the bug list."
  (dolist (scenario git-bug-tests--layout-scenarios)
    (let* ((name (nth 0 scenario))
           (git-bug-status-section-scope (nth 1 scenario))
           (bugs (nth 2 scenario))
           (git-bug-status-section-group-by-status (nth 3 scenario))
           (rows (git-bug-tests--layout-rows bugs)))
      (should rows)
      (let (status-starts title-starts label-starts reply-ends age-ends lengths)
        (dolist (row rows)
          (let* ((bug (car row))
                 (line (cdr row))
                 (title (git-bug--clean-title (alist-get 'title bug)))
                 (replies (git-bug--comment-count bug))
                 (age (git-bug--age-string (git-bug--bug-edit-time bug))))
            (push (string-match (regexp-quote (alist-get 'status bug)) line)
                  status-starts)
            (push (string-match (regexp-quote title) line) title-starts)
            (push (length line) lengths)
            (when (alist-get 'labels bug)
              (push (string-match "\\[" line) label-starts))
            (when (> replies 0)
              (should (string-match "([0-9]+)" line))
              (push (match-end 0) reply-ends))
            (should (string-match (concat (regexp-quote age) "\\'") line))
            (push (match-end 0) age-ends)))
        (git-bug-tests--should-align name "status column" status-starts)
        (git-bug-tests--should-align name "title column" title-starts)
        (git-bug-tests--should-align name "label column" label-starts)
        (git-bug-tests--should-align name "reply column" reply-ends)
        (git-bug-tests--should-align name "age column" age-ends)
        (git-bug-tests--should-align name "heading length" lengths)
        ;; A column absent from every bug is left out, not padded.
        (when (null label-starts)
          (should-not (string-match-p "\\[" (mapconcat #'cdr rows "\n"))))
        (when (null reply-ends)
          (should-not (string-match-p "([0-9])" (mapconcat #'cdr rows "\n"))))))))

(ert-deftest git-bug-tests-pure-helper-declarations ()
  "Pure helpers tell the byte compiler about their behavior."
  (dolist (fn '(git-bug--bug-author-fields
                git-bug--bug-time
                git-bug--author-display
                git-bug--clean-title
                git-bug--sorted-labels
                git-bug--comment-count
                git-bug--all-labels
                git-bug--all-authors
                git-bug--bug-edit-time
                git-bug--label-match
                git-bug--label-key-lessp
                git-bug--pad-cell))
    (should (function-get fn 'pure))
    (should (function-get fn 'side-effect-free)))
  (dolist (fn '(git-bug--select
                git-bug--check-scope
                git-bug--filter-bugs
                git-bug--sort-bugs
                git-bug--label-rank
                git-bug--best-label-rank
                git-bug--label-sort-key
                git-bug--displayed-bugs
                git-bug--heading-cells
                git-bug--heading-widths))
    ;; These read the clock or customizable variables, or signal on a
    ;; bad argument, so their result can change without an argument
    ;; change and they are not safe to evaluate at compile time.
    (should-not (function-get fn 'pure))
    (should (function-get fn 'side-effect-free))))

(ert-deftest git-bug-tests-sort-by-label-buckets ()
  "The label order sorts bugs into the buckets its rules name."
  (let* ((urgent '((id . "u")
                   (labels . ("urgent" "ui"))
                   (edit_time (timestamp . 1))))
         (p1 '((id . "1")
               (labels . ("priority:P1"))
               (edit_time (timestamp . 2))))
         (p2 '((id . "2")
               (labels . ("priority:P2"))
               (edit_time (timestamp . 3))))
         (plain '((id . "p")
                  (labels . ("ui"))
                  (edit_time (timestamp . 9))))
         (bare '((id . "n")
                 (edit_time (timestamp . 8))))
         (git-bug-status-section-sort 'label)
         (git-bug-status-section-label-order
          '("^urgent$" "^priority:P1$" "^priority:P2$")))
    ;; Buckets rank by rule, then the unmatched bugs by edit time.
    (should (equal (mapcar (lambda (bug) (alist-get 'id bug))
                           (git-bug--sort-bugs
                            (list bare plain p2 urgent p1)))
                   '("u" "1" "2" "p" "n")))
    (should (equal (git-bug--label-rank "priority:P2") '(2 . "")))
    (should-not (git-bug--label-rank "ui")))
  ;; An empty rule list leaves the edit-time order alone.
  (let ((git-bug-status-section-sort 'label)
        (git-bug-status-section-label-order nil)
        (a '((id . "a") (edit_time (timestamp . 10))))
        (b '((id . "b") (edit_time (timestamp . 20)))))
    (should (equal (mapcar (lambda (bug) (alist-get 'id bug))
                           (git-bug--sort-bugs (list a b)))
                   '("b" "a")))))

(ert-deftest git-bug-tests-sort-by-label-capture ()
  "A grouped rule sorts bugs by the text it captures."
  (let* ((p2 '((id . "2")
               (labels . ("priority:P2"))
               (edit_time (timestamp . 1))))
         (p9 '((id . "9")
               (labels . ("priority:P9"))
               (edit_time (timestamp . 2))))
         (p10 '((id . "10")
                (labels . ("priority:P10"))
                (edit_time (timestamp . 3))))
         (plain '((id . "p")
                  (labels . ("ui"))
                  (edit_time (timestamp . 4))))
         (git-bug-status-section-sort 'label)
         (git-bug-status-section-label-order
          '(("^priority:P\\([0-9]+\\)$" . 1))))
    (should (equal (mapcar (lambda (bug) (alist-get 'id bug))
                           (git-bug--sort-bugs (list p10 plain p2 p9)))
                   '("2" "9" "10" "p")))
    (should (equal (git-bug--label-match "priority:P10" (car git-bug-status-section-label-order))
                   "10"))
    ;; One bug takes its best match, not its last one.
    (should (equal (git-bug--best-label-rank '("priority:P2" "priority:P1"))
                   '(0 . "1")))))

(ert-deftest git-bug-tests-label-rule-matching ()
  "Label rules match one label at a time, case-sensitively."
  (should (equal (git-bug--label-match "urgent" "^urgent$") ""))
  (should-not (git-bug--label-match "urgent-ish" "^urgent$"))
  (should-not (git-bug--label-match "Urgent" "^urgent$"))
  ;; A rule outranks a capture group of a later rule.
  (let ((git-bug-status-section-label-order
         '("^priority:P1$" ("^priority:P\\([0-9]+\\)$" . 1))))
    (should (equal (git-bug--label-rank "priority:P1") '(0 . "")))
    (should (equal (git-bug--label-rank "priority:P5") '(1 . "5")))))

(ert-deftest git-bug-tests-sort-and-filter ()
  "Sorting and filtering operate on the list JSON."
  (let* ((a '((id . "b")
              (title . "Beta")
              (status . "open")
              (labels . ("ui"))
              (author (name . "Alice"))
              (edit_time (timestamp . 10))
              (create_time (timestamp . 20))))
         (b '((id . "a")
              (title . "Alpha")
              (status . "closed")
              (labels . ("bug"))
              (author (name . "Bob"))
              (edit_time (timestamp . 30))
              (create_time (timestamp . 5)))))
    (let ((git-bug-status-section-sort 'edit-time))
      (should (equal (mapcar (lambda (bug) (alist-get 'id bug))
                             (git-bug--sort-bugs (list a b)))
                     '("a" "b"))))
    (let ((git-bug-status-section-sort 'title))
      (should (equal (mapcar (lambda (bug) (alist-get 'title bug))
                             (git-bug--sort-bugs (list a b)))
                     '("Alpha" "Beta"))))
    (let ((git-bug-status-section-sort 'status))
      (should (equal (mapcar (lambda (bug) (alist-get 'id bug))
                             (git-bug--sort-bugs (list b a)))
                     '("a" "b"))))
    (let ((git-bug-status-section-label "ui"))
      (should (equal (git-bug--filter-bugs (list a b)) (list a))))
    (let ((git-bug-status-section-author "ali"))
      (should (equal (git-bug--filter-bugs (list a b)) (list a))))
    (let ((git-bug-status-section-label "bug")
          (git-bug-status-section-author "bob"))
      (should (equal (git-bug--displayed-bugs (list a b)) (list b))))))

(ert-deftest git-bug-tests-filter-commands ()
  "Interactive scope and filter commands set the customizations."
  (let ((git-bug-status-section-scope 'open)
        (git-bug-status-section-label nil)
        (git-bug-status-section-author nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "all"))
              ((symbol-function 'git-bug--refresh-current-status) #'ignore))
      (git-bug-set-scope)
      (should (eq git-bug-status-section-scope 'all)))
    (let ((git-bug-status-section-sort 'edit-time))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "label"))
                ((symbol-function 'git-bug--refresh-current-status) #'ignore))
        (git-bug-set-sort)
        (should (eq git-bug-status-section-sort 'label))))
    (git-bug-clear-filters)
    (should-not git-bug-status-section-label)
    (should-not git-bug-status-section-author)))

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

(ert-deftest git-bug-tests-detail-cache ()
  "Details cache per edit time and honor a force fetch."
  (clrhash git-bug--detail-cache)
  (let ((calls 0))
    (cl-letf (((symbol-function 'git-bug--fetch-detail)
               (lambda (&rest _)
                 (cl-incf calls)
                 '((id . "x") (edit_time (timestamp . 10))))))
      (git-bug--detail "/repo" "x" 10)
      (git-bug--detail "/repo" "x" 10)
      (should (= calls 1))
      (git-bug--detail "/repo" "x" 11)
      (should (= calls 2))
      (git-bug--detail "/repo" "x" 10 t)
      (should (= calls 3)))))

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
               (lambda (&rest _) (error "Boom"))))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward "Broken frobnicator")
        (goto-char (match-beginning 0))
        (magit-section-show (magit-current-section))
        (should (string-match-p "Details unavailable: Boom"
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

(ert-deftest git-bug-tests-body-fill-columns ()
  "`git-bug-body-fill' picks the width of a refilled body."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (let* ((body (concat "A paragraph whose single line is long enough to be "
                       "refilled into several shorter lines.\n"))
         (words (split-string body "[ \t\n]+" t)))
    ;; A number refills to that column, whatever `fill-column' says.
    (let* ((git-bug-body-fill 30)
           (fill-column 100)
           (filled (git-bug--fill-body body))
           (lines (split-string filled "\n" t)))
      (should (> (length lines) 1))
      (should (equal (split-string filled "[ \t\n]+" t) words))
      (should (cl-every (lambda (line) (<= (length line) 30)) lines)))
    ;; `t' refills to `fill-column'.
    (let* ((git-bug-body-fill t)
           (fill-column 20)
           (filled (git-bug--fill-body body))
           (lines (split-string filled "\n" t)))
      (should (> (length lines) 2))
      (should (cl-every (lambda (line) (<= (length line) 20)) lines)))
    ;; Nil keeps the authored lines.
    (let ((git-bug-body-fill nil))
      (should (equal (git-bug--fill-body body) body)))))

(ert-deftest git-bug-tests-body-fill-keeps-blocks ()
  "Refilling keeps headings, code blocks, tables and HTML as authored."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (let* ((atx "## A heading that runs past the fill column for sure")
         (setext (concat "A setext heading that runs past the column\n"
                         "--------------------------------------------------"))
         (code "A code line that runs past the fill column for sure.")
         (table "| a cell that runs past the column | b |\n|---|---|")
         (html (concat "<div>\n  <p>A paragraph in html that runs past "
                       "the column.</p>\n</div>"))
         (prose "A paragraph that runs past the fill column for sure.\n")
         ;; The heading follows the prose without a blank line between
         ;; them, as CommonMark allows a heading to interrupt a
         ;; paragraph.
         (body (concat prose atx "\n\n" setext "\n\n```\n" code
                       "\n```\n\n" table "\n\n" html "\n\n" prose))
         (git-bug-body-fill 20)
         (filled (git-bug--fill-body body)))
    ;; Every block stays exactly as authored, away from point-min too.
    (dolist (block (list atx setext code table html))
      (should (string-match-p (regexp-quote block) filled)))
    ;; The prose around them is refilled.
    (should-not (string-match-p (regexp-quote (string-trim prose)) filled))
    (should (string-match-p "for sure\\." filled))))

(ert-deftest git-bug-tests-body-fill-containers ()
  "Refilling reaches every paragraph of a list or a block quote."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (let* ((nested (concat "- An outer item that is long enough to need "
                         "refilling.\n"
                         "  - A nested item that is long enough to need "
                         "refilling.\n"))
         (item (concat "- First paragraph of an item that is long enough "
                       "to need refilling.\n\n"
                       "  Second paragraph of the item that is long enough "
                       "to need refilling.\n"))
         (quote (concat "> short\n>\n> A quoted paragraph that is long "
                        "enough to need refilling.\n"))
         (quoted (concat "- > A quoted paragraph inside a list item that "
                         "is long enough to refill.\n"))
         (body (concat nested "\n" item "\n" quote "\n" quoted))
         (git-bug-body-fill 30)
         (filled (git-bug--fill-body body)))
    ;; The nested item is refilled and keeps its indentation.
    (should (string-match-p "^  - A nested item that is long\n    enough"
                            filled))
    ;; So is the second paragraph of the item, not just the first.
    (should (string-match-p
             "^  Second paragraph of the item\n  that is long"
             filled))
    ;; The quoted paragraph keeps its markers.
    (should (string-match-p "^> A quoted paragraph that is\n> long enough"
                            filled))
    ;; So does a quote inside a list item.
    (should (string-match-p "^- > A quoted paragraph inside\n  > a list item"
                            filled))
    ;; The first paragraph of the item is refilled as well.
    (should (string-match-p "^- First paragraph of an item\n"
                            filled))))

(ert-deftest git-bug-tests-body-fill-in-views ()
  "Expanded sections and viewer buffers refill bug bodies."
  (skip-unless (git-bug--markdown-ts-ready-p))
  (git-bug-tests--with-repo repo
    (let* ((description
            "A description that is far too long for a single line.\n")
           (short (git-bug-tests--new-bug repo "Long body" description))
           (git-bug-body-fill 24)
           (buffer nil))
      (unwind-protect
          (progn
            (with-temp-buffer
              (git-bug-insert-status-bugs)
              (goto-char (point-min))
              (search-forward "Long body")
              (goto-char (match-beginning 0))
              (magit-section-show (magit-current-section))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should-not (string-match-p
                             (regexp-quote (string-trim description)) text))
                (should (string-match-p "far too long" text))
                (should (string-match-p "single line\\." text))))
            (setq buffer (git-bug-buffer repo short))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should-not (string-match-p
                             (regexp-quote (string-trim description)) text))
                (should (string-match-p "far too long" text))
                (should (string-match-p "single line\\." text)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest git-bug-tests-group-by-status ()
  "The all scope can split bugs into Open and Closed groups."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Open bug")
    (let ((closed (git-bug-tests--new-bug repo "Closed bug")))
      (git-bug--set-status repo closed "close")
      (let ((git-bug-status-section-scope 'all)
            (git-bug-status-section-group-by-status t))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (let ((text (buffer-string)))
            (should (string-match-p "Open (1)" text))
            (should (string-match-p "Closed (1)" text))
            (should (string-match-p "Open bug" text))
            (should (string-match-p "Closed bug" text))))))))

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
                (should (string-match-p "Participants: Test User"
                                        (buffer-string)))
                (should (string-match-p "Body with" (buffer-string)))
                (git-bug-toggle-status-in-buffer)
                (should (string-match-p "closed" (buffer-string))))))
        (when-let* ((buffer (get-buffer (format "*git-bug: %s*" short))))
          (kill-buffer buffer)))
      (should (equal (alist-get 'status (car (git-bug--list repo)))
                     "closed")))))

(ert-deftest git-bug-tests-revert-buffer ()
  "A revert re-reads the bug from storage, bypassing the cache."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Broken frobnicator"))
           (bug (car (git-bug--list repo))))
      (unwind-protect
          (progn
            (git-bug-show-bug repo bug)
            (let ((buffer (get-buffer (format "*git-bug: %s*" short))))
              (should buffer)
              (with-current-buffer buffer
                (should (eq revert-buffer-function
                            #'git-bug--revert-buffer))
                (should (eq (lookup-key git-bug-mode-map (kbd "g"))
                            #'revert-buffer))
                (should-not (string-match-p "Late comment"
                                            (buffer-string)))
                (git-bug--add-comment repo (alist-get 'id bug)
                                      "Late comment\n")
                ;; The comment refreshed the cache and the viewer, but
                ;; the buffer still shows the text from before it, since
                ;; the write ran in this buffer.
                (revert-buffer-quick)
                (should (string-match-p "Late comment"
                                        (buffer-string))))))
        (when-let* ((buffer (get-buffer (format "*git-bug: %s*" short))))
          (kill-buffer buffer))))))

(ert-deftest git-bug-tests-bug-section-keys ()
  "Bug headings expose view, copy, toggle, comment and label keys."
  (should (eq (lookup-key git-bug-bug-section-map (kbd "RET"))
              #'git-bug-show-bug-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "w"))
              #'git-bug-copy-id-at-point))
  (should (eq (lookup-key git-bug-bug-section-map (kbd "W"))
              #'git-bug-copy-full-id-at-point))
  ;; package-lint rejects the literal "C-c <letter>" form, so build the
  ;; sequence from its parts.
  (should (eq (lookup-key git-bug-bug-section-map (vconcat (kbd "C-c") "r"))
              #'git-bug-copy-ref-at-point))
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

(ert-deftest git-bug-tests-bugs-section-keys ()
  "The Bugs heading exposes create, filter and sort commands."
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "n"))
              #'git-bug-new-bug))
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "s"))
              #'git-bug-set-scope))
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "l"))
              #'git-bug-filter-label))
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "a"))
              #'git-bug-filter-author))
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "S"))
              #'git-bug-set-sort))
  (should (eq (lookup-key git-bug-bugs-section-map (kbd "c"))
              #'git-bug-clear-filters)))

(ert-deftest git-bug-tests-new-bug-command ()
  "The interactive command creates a bug after composition."
  (git-bug-tests--with-repo repo
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "Command bug"))
              ((symbol-function 'git-bug--compose)
               (lambda (_description _initial callback)
                 (funcall callback "Body from command.\n"))))
      (git-bug-new-bug))
    (let ((bug (car (git-bug--list repo))))
      (should (equal (alist-get 'title bug) "Command bug")))))

(ert-deftest git-bug-tests-edit-labels-command ()
  "The label command applies a completed label list."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Broken frobnicator"))
           (bug (car (git-bug--list repo)))
           (full (alist-get 'id bug)))
      (cl-letf (((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) '("x" "y"))))
        (with-temp-buffer
          (git-bug-insert-status-bugs)
          (goto-char (point-min))
          (search-forward short)
          (goto-char (match-beginning 0))
          (git-bug-edit-labels-at-point)))
      (should (equal (git-bug--sorted-labels
                      (alist-get 'labels (git-bug--detail repo full)))
                     '("x" "y"))))))

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

(ert-deftest git-bug-tests-copy-reference-variants ()
  "Copy the short id, full id and ref of a bug."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Broken frobnicator"))
           (bug (car (git-bug--list repo)))
           (full (alist-get 'id bug)))
      (with-temp-buffer
        (git-bug-insert-status-bugs)
        (goto-char (point-min))
        (search-forward short)
        (goto-char (match-beginning 0))
        (git-bug-copy-id-at-point '(4))
        (should (equal (car kill-ring) full))
        (git-bug-copy-ref-at-point)
        (should (equal (car kill-ring) (format "refs/bugs/%s" full)))))))

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

(defun git-bug-tests--fake-program (body)
  "Create an executable script with BODY."
  (let ((script (make-temp-file "git-bug-fake" nil ".sh"))
        (shell (or (executable-find "bash") (executable-find "sh"))))
    (with-temp-file script
      (insert "#!" shell "\n" body))
    (set-file-modes script #o755)
    script))

(ert-deftest git-bug-tests-call-environment ()
  "Subprocesses get quiet git settings and UTF-8 coding."
  (let* ((repo (file-name-as-directory
                (make-temp-file "git-bug-tests" t)))
         (script (git-bug-tests--fake-program
                  "printf '%s|%s|%s\n' \"$GIT_PAGER\" \"$PAGER\" \"$GIT_OPTIONAL_LOCKS\"\n")))
    (unwind-protect
        (let ((git-bug-program script))
          (should (equal (git-bug--call repo) "cat|cat|0\n")))
      (delete-file script)
      (delete-directory repo t))))

(ert-deftest git-bug-tests-call-stdin ()
  "Standard input reaches git-bug unchanged."
  (let* ((repo (file-name-as-directory
                (make-temp-file "git-bug-tests" t)))
         (script (git-bug-tests--fake-program "cat\n")))
    (unwind-protect
        (let ((git-bug-program script))
          (should (equal (git-bug--call-with-input repo "hello\n")
                         "hello\n")))
      (delete-file script)
      (delete-directory repo t))))

(ert-deftest git-bug-tests-call-error-type ()
  "CLI failures signal `git-bug-call-failed' with the call context."
  (let* ((repo (file-name-as-directory
                (make-temp-file "git-bug-tests" t)))
         (script (git-bug-tests--fake-program
                  "printf 'boom\\n' >&2\nexit 3\n")))
    (unwind-protect
        (let* ((git-bug-program script)
               (err (should-error (git-bug--call repo "bug")
                                  :type 'git-bug-error))
               (data (git-bug-error-data err)))
          (should (eq (car err) 'git-bug-call-failed))
          (should (equal (plist-get data :exit) 3))
          (should (equal (plist-get data :stderr) "boom"))
          (should (plist-get data :args)))
      (delete-file script)
      (delete-directory repo t))))

(ert-deftest git-bug-tests-call-missing-program ()
  "A missing git-bug binary is not a generic file error."
  (let* ((repo (file-name-as-directory
                (make-temp-file "git-bug-tests" t)))
         (git-bug-program "/nonexistent/git-bug"))
    (unwind-protect
        (let* ((err (should-error (git-bug--call repo)))
               (data (git-bug-error-data err)))
          (should (eq (car err) 'git-bug-missing-program))
          (should (equal (plist-get data :program) "/nonexistent/git-bug")))
      (delete-directory repo t))))

(ert-deftest git-bug-tests-call-missing-repo ()
  "A directory that does not exist is a bad argument, not a bad program."
  (let* ((err (should-error (git-bug--call "/nonexistent/git-bug-repo")))
         (data (git-bug-error-data err)))
    (should (eq (car err) 'git-bug-invalid-argument))
    (should (equal (plist-get data :value) "/nonexistent/git-bug-repo"))))

(ert-deftest git-bug-tests-call-invalid-json ()
  "Unparseable output is its own condition."
  (let ((err (should-error (git-bug--parse-json "{not json"))))
    (should (eq (car err) 'git-bug-invalid-output))))

;;; Library surface

(ert-deftest git-bug-tests-library-surface ()
  "Every documented entry point exists and subclasses `git-bug-error'."
  (dolist (fn '(git-bug-list git-bug-get git-bug-field
                git-bug-format-bug git-bug-format-bug-list
                git-bug-buffer git-bug-show git-bug-forget
                git-bug-error-data))
    (should (fboundp fn)))
  (dolist (condition '(git-bug-call-failed git-bug-missing-program
                       git-bug-invalid-output git-bug-invalid-argument))
    (should (memq condition (get condition 'error-conditions)))
    (should (memq 'git-bug-error (get condition 'error-conditions)))))

(ert-deftest git-bug-tests-library-field ()
  "Fields read by name, whatever case an answer spells them in."
  (let ((bug '((id . "abc") (HUMAN_ID . "abc1234") (labels . nil))))
    (should (equal (git-bug-field bug 'id) "abc"))
    (should (equal (git-bug-field bug 'human_id) "abc1234"))
    (should (equal (git-bug-field bug "Human_Id") "abc1234"))
    (should-not (git-bug-field bug 'missing))
    (should-not (git-bug-field nil 'id))))

(ert-deftest git-bug-tests-library-list ()
  "The library list honors its filters and agrees with the section."
  (git-bug-tests--with-repo repo
    (let ((one (git-bug-tests--new-bug repo "Alpha"))
          (two (git-bug-tests--new-bug repo "Beta")))
      (git-bug--call repo "bug" "label" "new" one "ui")
      (git-bug--call repo "bug" "status" "close" two)
      (let ((titles (lambda (bugs)
                      (mapcar (lambda (bug) (git-bug-field bug 'title))
                              bugs))))
        (should (equal (funcall titles (git-bug-list repo)) '("Alpha")))
        (should (= (length (git-bug-list repo '(:scope all))) 2))
        (should (equal (funcall titles
                                (git-bug-list repo '(:scope all :sort title)))
                       '("Alpha" "Beta")))
        (should (equal (funcall titles (git-bug-list repo '(:scope all :label "ui")))
                       '("Alpha")))
        (should (equal (funcall titles
                                (git-bug-list repo
                                              '(:scope all :author "test user"
                                                :sort title)))
                       '("Alpha" "Beta"))))
      ;; The defaults match what the status section shows.
      (should (equal (git-bug-list repo)
                     (git-bug--select
                      (git-bug--displayed-bugs (git-bug--list repo))
                      git-bug-status-section-scope))))))

(ert-deftest git-bug-tests-library-list-invalid-scope ()
  "An unknown scope is a package condition, not a bare error."
  (let ((err (should-error (git-bug--select nil 'bogus))))
    (should (eq (car err) 'git-bug-invalid-argument))
    (should (eq (plist-get (git-bug-error-data err) :value) 'bogus))))

(ert-deftest git-bug-tests-library-get ()
  "Get returns one full bug, by full or short id."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Alpha" "Body text.\n"))
           (full (git-bug-field (car (git-bug--list repo)) 'id))
           (detail (git-bug-get repo full)))
      (should (equal (git-bug-field detail 'id) full))
      (should (listp (git-bug-field detail 'comments)))
      (should (string-match-p "Body text"
                              (git-bug-field (car (git-bug-field detail 'comments))
                                             'message)))
      ;; A short id resolves, and the answer caches under the full id.
      (should (equal (git-bug-field (git-bug-get repo short) 'id) full))
      (should (git-bug--cached-detail (git-bug--repo-key repo) full))
      (should-not (git-bug--cached-detail (git-bug--repo-key repo) short))
      ;; An unknown id is a failed call, with the exit status attached.
      (let* ((err (should-error (git-bug-get repo (make-string 40 ?0))))
             (data (git-bug-error-data err)))
        (should (eq (car err) 'git-bug-call-failed))
        (should (equal (plist-get data :exit) 1))
        (should (plist-get data :stderr))))))

(ert-deftest git-bug-tests-library-ttl ()
  "The cache honors `git-bug-detail-ttl'."
  (clrhash git-bug--detail-cache)
  (let ((calls 0)
        (git-bug-change-functions nil))
    (cl-letf (((symbol-function 'git-bug--fetch-detail)
               (lambda (&rest _)
                 (cl-incf calls)
                 '((id . "x") (edit_time (timestamp . 1))))))
      (let ((git-bug-detail-ttl nil))
        (git-bug-get "/repo" "x")
        (git-bug-get "/repo" "x")
        (should (= calls 1)))
      (let ((git-bug-detail-ttl 0))
        (git-bug-get "/repo" "x")
        (should (= calls 2)))
      (let ((git-bug-detail-ttl 3600))
        (git-bug-get "/repo" "x")
        (should (= calls 2))))))

(ert-deftest git-bug-tests-library-forget ()
  "Forget drops cached bugs by scope and reports what goes away."
  (clrhash git-bug--detail-cache)
  (let* (events
         (git-bug-change-functions
          (list (lambda (event) (push event events)))))
    (cl-letf (((symbol-function 'git-bug--fetch-detail)
               (lambda (repo _id)
                 (list (cons 'id "x") (cons 'title repo)
                       (cons 'edit_time (list (cons 'timestamp 1)))))))
      (git-bug-get "/one" "x")
      (git-bug-get "/two" "x")
      (should (= (hash-table-count git-bug--detail-cache) 2))
      (git-bug-forget "/one")
      (should (= (hash-table-count git-bug--detail-cache) 1))
      (should (= (length events) 1))
      (let ((event (car events)))
        (should (eq (plist-get event :event) 'invalidate))
        (should (equal (plist-get event :repo) "/one"))
        (should (equal (plist-get event :id) "x"))
        (should (git-bug-field (plist-get event :old) 'title))
        (should-not (plist-get event :new)))
      (git-bug-forget)
      (should (zerop (hash-table-count git-bug--detail-cache)))
      (should (= (length events) 2)))))

(ert-deftest git-bug-tests-library-forget-human-id ()
  "Forget accepts the short id that a heading shows."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Alpha"))
           (full (git-bug-field (car (git-bug--list repo)) 'id)))
      (git-bug-get repo full)
      (should (git-bug--cached-detail (git-bug--repo-key repo) full))
      (git-bug-forget repo short)
      (should-not (git-bug--cached-detail (git-bug--repo-key repo) full)))))

(ert-deftest git-bug-tests-library-forget-keeps-dropped ()
  "Forget drops the entry, and a viewer does not fetch it back."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Alpha"))
           (full (git-bug-field (car (git-bug--list repo)) 'id))
           (buffer (git-bug-buffer repo full)))
      (unwind-protect
          (progn
            (should (git-bug--cached-detail (git-bug--repo-key repo) full))
            (git-bug-forget repo short)
            (should-not (git-bug--cached-detail (git-bug--repo-key repo) full))
            ;; The view keeps its text and re-reads storage later.
            (with-current-buffer buffer
              (should (string-match-p "Alpha" (buffer-string)))
              (git-bug-refresh-buffer)
              (should (string-match-p "Alpha" (buffer-string))))
            (should (git-bug--cached-detail (git-bug--repo-key repo) full)))
        (kill-buffer buffer)))))

(ert-deftest git-bug-tests-library-change-hook ()
  "A write reports one change event; an equal fetch reports none."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Alpha")
    (let* ((full (git-bug-field (car (git-bug--list repo)) 'id))
           events)
      (git-bug-get repo full)
      (let ((git-bug-change-functions
             (list (lambda (event) (push event events)))))
        (git-bug--set-status repo full "close")
        (should (= (length events) 1))
        (let ((event (car events)))
          (should (eq (plist-get event :event) 'change))
          (should (eq (plist-get event :type) 'bug))
          (should (eq (plist-get event :kind) 'show))
          (should (equal (plist-get event :repo) (git-bug--repo-key repo)))
          (should (equal (plist-get event :id) full))
          (should (equal (git-bug-field (plist-get event :old) 'status) "open"))
          (should (equal (git-bug-field (plist-get event :new) 'status) "closed")))
        (git-bug-get repo full t)
        (should (= (length events) 1))
        ;; A write reports a change even without a cached answer.
        (git-bug-forget repo full)
        (setq events nil)
        (git-bug--set-status repo full "open")
        (should (= (length events) 1))
        (should-not (plist-get (car events) :old))))))

(ert-deftest git-bug-tests-library-create-event ()
  "Creating a bug reports a create event."
  (git-bug-tests--with-repo repo
    (let* (events
           (git-bug-change-functions
            (list (lambda (event) (push event events)))))
      (git-bug--create-bug repo "Fresh" "Body.\n")
      (should (= (length events) 1))
      (should (eq (plist-get (car events) :event) 'create))
      (should-not (plist-get (car events) :old))
      (should (equal (git-bug-field (plist-get (car events) :new) 'title)
                     "Fresh")))))

(ert-deftest git-bug-tests-library-buffer ()
  "The viewer builds a buffer without displaying it."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Alpha" "Body.\n"))
           (full (git-bug-field (car (git-bug--list repo)) 'id)))
      (unwind-protect
          (with-temp-buffer
            (let ((here (current-buffer))
                  (buffer (git-bug-buffer repo full)))
              (should (eq (current-buffer) here))
              (should (eq buffer (git-bug-buffer repo full)))
              (with-current-buffer buffer
                (should (derived-mode-p 'git-bug-mode))
                (should buffer-read-only)
                (should (equal git-bug--buffer-id full))
                (should (equal git-bug--buffer-human-id short))
                (should (equal git-bug--buffer-repo (git-bug--repo-key repo)))
                (should (string-match-p "Alpha" (buffer-string)))))
            (should-error (git-bug-buffer repo full 'no-such-mode)
                          :type 'user-error)
            (git-bug-show repo full)
            (should (derived-mode-p 'git-bug-mode))
            (should (string-match-p "Alpha" (buffer-string))))
        (when-let* ((buffer (get-buffer (format "*git-bug: %s*" short))))
          (kill-buffer buffer))))))

(ert-deftest git-bug-tests-library-buffer-bad-mode ()
  "A mode outside `git-bug-mode' signals before a buffer exists."
  (git-bug-tests--with-repo repo
    (let* ((short (git-bug-tests--new-bug repo "Alpha"))
           (full (git-bug-field (car (git-bug--list repo)) 'id))
           (name (git-bug--viewer-name short full)))
      (unwind-protect
          (progn
            (should-error (git-bug-buffer repo full 'fundamental-mode)
                          :type 'user-error)
            (should-not (get-buffer name)))
        (when-let* ((buffer (get-buffer name)))
          (kill-buffer buffer))))))

(ert-deftest git-bug-tests-library-write-fetches-once ()
  "Toggling in a viewer reads the bug back once and needs no hook."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Alpha")
    (let* ((full (git-bug-field (car (git-bug--list repo)) 'id))
           (buffer (git-bug-buffer repo full))
           ;; The package refreshes its own views, so replacing the
           ;; public hook must not stop a write from updating them.
           (git-bug-change-functions nil)
           (fetches 0))
      (unwind-protect
          (cl-letf* ((fetch (symbol-function 'git-bug--fetch-detail))
                     ((symbol-function 'git-bug--fetch-detail)
                      (lambda (&rest args)
                        (cl-incf fetches)
                        (apply fetch args))))
            (with-current-buffer buffer
              (git-bug-toggle-status-in-buffer)
              (should (equal git-bug--buffer-status "closed"))
              (should (string-match-p "closed" (buffer-string)))))
        (kill-buffer buffer))
      (should (= fetches 1)))))

(ert-deftest git-bug-tests-library-viewer-refresh ()
  "A change refreshes an open viewer whatever its buffer name."
  (git-bug-tests--with-repo repo
    (git-bug-tests--new-bug repo "Alpha")
    (let* ((full (git-bug-field (car (git-bug--list repo)) 'id))
           (buffer (git-bug-buffer repo full)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (rename-buffer "git-bug-tests-viewer"))
            (git-bug--add-comment repo full "Late comment\n")
            (with-current-buffer buffer
              (should (equal (buffer-name) "git-bug-tests-viewer"))
              (should (string-match-p "Late comment" (buffer-string)))))
        (kill-buffer buffer)))))

(ert-deftest git-bug-tests-library-format ()
  "The text renderers need no buffer, align and honor the faces flag."
  (let* ((bugs (list (git-bug-tests--fake-bug "1a2b3c4" "Short" "open"
                                               '("ui") 1 60)
                     (git-bug-tests--fake-bug "5d6e7f8" "A longer title" "open"
                                               '("core") 0 90)))
         (git-bug-status-section-sort 'id)
         (git-bug-status-section-label nil)
         (git-bug-status-section-author nil)
         (git-bug-status-section-scope 'open))
    (let* ((text (git-bug-format-bug-list bugs nil))
           (lines (split-string text "\n")))
      (should-not (text-properties-at 0 text))
      (should (= (length lines) 2))
      (should (apply #'= (mapcar (lambda (line) (string-match "\\[" line)) lines)))
      ;; The renderer and the section agree line by line.
      (with-temp-buffer
        (git-bug--insert-bugs "/nonexistent/" bugs)
        (dolist (line lines)
          (should (string-match-p
                   (regexp-quote line)
                   (buffer-substring-no-properties (point-min) (point-max)))))))
    (let ((faces (git-bug-format-bug (car bugs) t))
          (plain (git-bug-format-bug (car bugs) nil)))
      (should (text-property-not-all 0 (length faces) 'font-lock-face nil faces))
      (should (string-match-p "\\[ui\\]" faces))
      (should (equal (substring-no-properties faces) plain)))
    (should (equal (git-bug-format-bug-list nil) ""))))

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

(provide 'git-bug-test)

;;; git-bug-test.el ends here
