;;; erlstack-mode.el --- Minor mode for analyzing Erlang stacktraces  -*- lexical-binding: t; -*-

;; Author: k32
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(provide 'erlstack-mode)
(require 'dash)

(defun erlstack-whitespacify-concat (&rest re)
  "Intercalate strings with regexp matching whitespace"
  (--reduce (concat acc "[ \t\n]*" it) re))

(defvar erlstack-overlay nil)
(defvar erlstack-code-overlay nil)
(defvar erlstack-code-window nil)
(defvar erlstack-code-window-active nil)
(defvar erlstack-code-buffer nil)
(defvar-local erlstack-buffer-file-name nil)
(defvar-local erlstack-current-location nil)

(defvar erlstack-frame-mode-map
  (make-sparse-keymap))

(define-key erlstack-frame-mode-map (kbd "C-<return>") 'erlstack-visit-file)
(define-key erlstack-frame-mode-map (kbd "C-<up>")     'erlstack-up-frame)
(define-key erlstack-frame-mode-map (kbd "C-<down>")   'erlstack-down-frame)

(defvar erlstack-string-re
  "\"\\([^\"]*\\)\"")

(defvar erlstack-file-re
  (erlstack-whitespacify-concat "{" "file" "," erlstack-string-re "}"))

(defvar erlstack-line-re
  (erlstack-whitespacify-concat "{" "line" "," "\\([[:digit:]]+\\)" "}"))

(defvar erlstack-position-re
  (erlstack-whitespacify-concat "\\[" erlstack-file-re "," erlstack-line-re "]"))

(defvar erlstack-stack-frame-re
  (erlstack-whitespacify-concat "{[^{}]*" erlstack-position-re "}"))

(defvar erlstack-stack-end-re
  "}]}")

(defcustom erlstack-file-search-hook
  '(erlstack-locate-abspath)
  "List of hooks used to search project files"
  :options '(erlstack-locate-abspath
             erlstack-locate-otp
             erlstack-locate-projectile)
  :group 'erlstack
  :type 'hook)

(defcustom erlstack-lookup-window
  300
  "Size of lookup window"
  :group 'erlstack
  :type 'integer)

(defface erlstack-frame-face
  '((((background light))
     :background "orange"
     :foreground "darkred")
    (((background dark))
     :background "orange"
     :foreground "red"))
  "The face for matched `erlstack' stack frame")

(defun erlstack-frame-found (begin end)
  "This fuction is called when point enters stack frame"
  (let ((query       (match-string 1))
        (line-number (string-to-number (match-string 2))))
    (erlstack-try-show-file query line-number)
    (setq erlstack-overlay (make-overlay begin end))
    (set-transient-map erlstack-frame-mode-map t)
    (overlay-put erlstack-overlay 'face 'erlstack-frame-face)))

(defun erlstack-try-show-file (query line-number)
  "Search for a file"
  (let ((filename
         (run-hook-with-args-until-success 'erlstack-file-search-hook query line-number)))
    (if filename
        (progn
          (setq-local erlstack-current-location `(,filename ,line-number))
          (erlstack-code-popup filename line-number))
      (erlstack-frame-lost))))

(defun erlstack-code-popup (filename line-number)
  "Opens a pop-up window with the code"
  (setq erlstack-code-buffer (find-file-noselect filename t))
  (with-current-buffer erlstack-code-buffer
    (with-no-warnings
      (goto-line line-number))
    (setq erlstack-code-buffer-posn (point))
    (setq erlstack-code-overlay (make-overlay
                                 (line-beginning-position)
                                 (line-end-position)))
    (overlay-put erlstack-code-overlay 'face 'erlstack-frame-face)
    (setq erlstack-code-window (display-buffer-in-side-window
                                erlstack-code-buffer
                                '((display-buffer-reuse-window
                                   display-buffer-pop-up-window))))
    (setq erlstack-code-window-active t)
    (set-window-point erlstack-code-window erlstack-code-buffer-posn)))

(defun erlstack-visit-file ()
  "Open file related to the currently selected stack frame for
editing"
  (interactive)
  (when erlstack-code-window-active
    (setq erlstack-code-window-active nil)
    (pcase erlstack-current-location
      (`(,filename ,line-number)
       (select-window erlstack-code-window)
       (with-no-warnings
         (goto-line line-number))))))

(defun erlstack-locate-abspath (query line)
  "Try search for local file with absolute path"
  (when (file-exists-p query)
    query))

(defun erlstack-frame-lost ()
  "This fuction is called when point leaves stack frame"
  (when erlstack-code-window-active
    ;; (switch-to-prev-buffer erlstack-code-window)
    (delete-side-window erlstack-code-window)
    (setq erlstack-code-window-active nil)))

(defun erlstack-run-at-point ()
  "Attempt to analyze stack frame at the point"
  (interactive)
  (run-with-idle-timer
   0.1 nil
   (lambda ()
     (when erlstack-overlay
       (delete-overlay erlstack-overlay))
     (when erlstack-code-overlay
       (delete-overlay erlstack-code-overlay))
     (pcase (erlstack-parse-at-point)
       (`(,begin ,end) (erlstack-frame-found begin end))
       (_              (erlstack-frame-lost))))))

(defun erlstack-parse-at-point ()
  "Attempt to find stacktrace at point"
  (save-excursion
    (let ((point (point))
          (end (re-search-forward erlstack-stack-end-re
                                  (+ (point) erlstack-lookup-window) t))
          (begin (re-search-backward erlstack-stack-frame-re
                                     (- (point) erlstack-lookup-window) t)))
      (when (and begin end (>= point begin))
        `(,begin ,end)))))

(defun erlstack-goto-stack-begin ()
  (goto-char (nth 0 (erlstack-parse-at-point))))

(defun erlstack-goto-stack-end ()
  (goto-char (nth 1 (erlstack-parse-at-point))))

;; (defun erlstack-check-rebar-tmp-dir ()
;;   "Check if the opened Erlang file is a temporary one created by
;; rebar and prompt to open the original. Basically it detects
;; presense of \"_build\" directory in the path and tries to guess
;; original path"
;;   (interactive)

(defmacro erlstack-jump-frame (fun dir)
  `(let* ((bound      (,dir (point) erlstack-lookup-window))
          (next-frame (save-excursion
                        (erlstack-goto-stack-begin)
                        ,fun)))
     (when next-frame
       (goto-char next-frame)
       (erlstack-goto-stack-begin))))

(defun erlstack-up-frame ()
  "Move one stack frame up"
  (interactive)
  (erlstack-jump-frame
   (re-search-backward erlstack-file-re bound t) -))

(defun erlstack-down-frame ()
  "Move one stack frame down"
  (interactive)
  (erlstack-jump-frame
   (re-search-forward erlstack-file-re bound t 2) +))

(define-minor-mode erlstack-mode
 "Parse Erlang stacktrace under point and quickly navigate to the
line of the code"
 :keymap nil
 :group 'erlstack
 :lighter " es"
 :global t
 (if erlstack-mode
     (add-hook 'post-command-hook #'erlstack-run-at-point)
   (remove-hook 'post-command-hook #'erlstack-run-at-point)))

;;; Example stacktrace:
;;
;; [{shell,apply_fun,3,[{file,"shell.erl"},{line,907}]},
;;  {erl_eval,do_apply,6,[{file,"erl_eval.erl"},{line,681}]},
;;  {erl_eval,try_clauses,8,[{file,"erl_eval.erl"},{line,911}]},
;;  { shell , exprs , 7 , [{file,"shell.erl"},{line,686}]},{shell,eval_exprs,7,[{file,"shell.erl"},{line,642}]},
;;  {shell,eval_loop,3,[ {file,"shell.erl"}, {line,627}]}]


;;; erlstack-mode.el ends here
