;;; preview.el --- Print rendered Bugs sections for eyeballing -*- lexical-binding: t -*-

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

;; Layout harness for the Bugs section, not part of the ERT suite
;; (the glob in `flake.nix' only loads `test/*-test.el').  It renders
;; a few fixed bug lists through the real rendering code and prints
;; them, so column alignment can be judged by eye instead of through
;; assertions.  Run it inside the development shell:
;;
;;   emacs -Q --batch -L . -L test -l test/preview.el
;;
;; The fake bugs need no repository and no git-bug binary.

;;; Code:

(require 'git-bug)

(defun git-bug-preview--bug (human title status labels replies age)
  "Return a fake bug for the preview.
HUMAN is the short id, TITLE the title, STATUS either \"open\" or
\"closed\", LABELS the label list, REPLIES the number of comments
and AGE the edit age in seconds."
  (let ((now (float-time)))
    `((id . ,(concat human (make-string 33 ?0)))
      (human_id . ,human)
      (title . ,title)
      (status . ,status)
      (labels . ,labels)
      ;; Git-bug counts the description as comment zero.
      (comments . ,(1+ replies))
      (edit_time . ((timestamp . ,(- now age))))
      (create_time . ((timestamp . ,(- now age)))))))

(defvar git-bug-preview--mixed
  (list (git-bug-preview--bug "1a2b3c4" "Short" "open" '("ui") 2 120)
        (git-bug-preview--bug "5d6e7f8" "A considerably longer bug title"
                              "closed" '("core" "urgent") 0 90000)
        (git-bug-preview--bug "9a0b1c2" "Medium" "open" nil 1 4000)
        (git-bug-preview--bug "3d4e5f6" "Same width" "open" '("docs") 0 30))
  "Bugs of mixed status, title length, labels and ages.")

(defvar git-bug-preview--open
  (list (git-bug-preview--bug "1a2b3c4" "Short" "open" nil 0 90)
        (git-bug-preview--bug "5d6e7f8" "A considerably longer bug title"
                              "open" nil 0 7200)
        (git-bug-preview--bug "9a0b1c2" "Medium" "open" nil 0 30))
  "Only open bugs, no labels and no replies.")

(defvar git-bug-preview--closed
  (list (git-bug-preview--bug "1a2b3c4" "Fixed thing" "closed" '("fixed") 1
                              (* 86400 40))
        (git-bug-preview--bug "5d6e7f8" "Wontfix" "closed" '("wontfix") 0
                              (* 86400 3)))
  "Only closed bugs.")

(defvar git-bug-preview--scenarios
  (list (list "open" 'open git-bug-preview--open)
        (list "closed" 'closed git-bug-preview--closed)
        (list "mixed" 'open git-bug-preview--mixed)
        (list "all" 'all git-bug-preview--mixed)
        (list "all, grouped" 'all git-bug-preview--mixed 'group))
  "Preview scenarios, as a list of (NAME SCOPE BUGS) lists.
The optional fourth element groups the bugs by status.")

(defun git-bug-preview--string (bugs)
  "Return the rendered Bugs section for BUGS as a string."
  (with-temp-buffer
    (git-bug--insert-bugs "/nonexistent/" bugs)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun git-bug-preview--ruler (width)
  "Return a column ruler WIDTH characters wide.
Tens digits mark every tenth column, used to read off alignment."
  (let ((ruler (make-string width ?.)))
    (dotimes (column width)
      (when (zerop (% column 10))
        (aset ruler column ?|)))
    (concat ruler "\n")))

;;;###autoload
(defun git-bug-preview-print ()
  "Print every preview scenario followed by a column ruler."
  (dolist (scenario git-bug-preview--scenarios)
    (let* ((name (nth 0 scenario))
           (git-bug-status-section-scope (nth 1 scenario))
           (bugs (nth 2 scenario))
           (git-bug-status-section-group-by-status
            (equal (nth 3 scenario) 'group))
           (text (git-bug-preview--string bugs))
           (width (apply #'max 60
                         (mapcar #'length (split-string text "\n")))))
      (princ (format "== %s ==\n" name))
      (princ (git-bug-preview--ruler width))
      (princ text)
      (princ "\n"))))

(git-bug-preview-print)

(provide 'preview)

;;; preview.el ends here
