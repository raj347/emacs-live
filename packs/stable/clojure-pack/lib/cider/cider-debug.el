;;; cider-debug.el --- CIDER interaction with clj-debugger  -*- lexical-binding: t; -*-

;; Copyright © 2015 Artur Malabarba

;; Author: Artur Malabarba <bruce.connor.am@gmail.com>

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

;; Instrument code with `cider-debug-defun-at-point', and when the code is
;; executed cider-debug will kick in.  See this function's doc for more
;; information.

;;; Code:

(require 'nrepl-client)
(require 'cider-interaction)

(defface cider-result-overlay-face
  '((((class color) (background light)) :foreground "firebrick")
    (((class color) (background dark))  :foreground "orange red"))
  "Face used to display result of debug step at point."
  :group 'cider
  :package-version "0.9.1")

(defface cider-debug-code-overlay-face
  '((((class color) (background light)) :background "grey80")
    (((class color) (background dark))  :background "grey30"))
  "Face used to mark code being debugged."
  :group 'cider
  :package-version "0.9.1")

(defcustom cider-debug-use-overlays 'end-of-line
  "Whether to higlight debugging information with overlays.
Only applies to \"*cider-debug ...*\" buffers, which are used in debugging
sessions.
Possible values are inline, end-of-line, or nil."
  :type '(choice (const :tag "End of line" end-of-line)
                 (const :tag "Inline" inline)
                 (const :tag "No overlays" nil))
  :group 'cider
  :package-version "0.9.1")

(defconst cider--instrument-format
  (concat "(cider.nrepl.middleware.debug/instrument-and-eval"
          ;; filename and point are passed in a map. Eventually, this should be
          ;; part of the message (which the nrepl sees as a map anyway).
          " {:filename %S :point %S} '%s)")
  "Format to instrument an expression given a file and a coordinate.")


;;; Implementation
(defun cider--debug-init-connection ()
  "Initialize a connection with clj-debugger."
  (nrepl-send-request
   '("op" "init-debugger")
   (lambda (response)
     (nrepl-dbind-response response (status id)
       (if (not (member "done" status))
           (cider--handle-debug response)
         (puthash id (gethash id nrepl-pending-requests)
                  nrepl-completed-requests)
         (remhash id nrepl-pending-requests))))))


;;; Overlay logic
(defun cider--delete-overlay (ov &rest _)
  "Safely delete overlay OV.
Never throws errors, and can be used in an overlay's modification-hooks."
  (ignore-errors (delete-overlay ov)))

(defun cider--make-overlay (l r type &rest props)
  "Place an overlay between L and R and return it.
TYPE is a symbol put on the overlay's cider-type property. It is used to
easily remove all overlays from a region with:
    (remove-overlays start end 'cider-type TYPE)
PROPS is a plist of properties and values to add to the overlay."
  (let ((o (make-overlay l r (current-buffer))))
    (overlay-put o 'cider-type type)
    (overlay-put o 'modification-hooks (list #'cider--delete-overlay))
    (while props (overlay-put o (pop props) (pop props)))
    o))

(defun cider--make-result-overlay (value type &optional where &rest props)
  "Place an overlay displaying VALUE at the end of the line.
TYPE and PROPS are passed to `cider--make-overlay'.
The overlay is placed from beginning to end of current line.
If WHERE is the symbol inline, instead, the overlay ends at point and VALUE
is displayed at point."
  (apply
   #'cider--make-overlay
   (line-beginning-position)
   (if (eq where 'inline) (point) (line-end-position))
   'debug-result
   'after-string
   (propertize (concat (propertize " " 'cursor 1000)
                       cider-interactive-eval-result-prefix
                       (format "%s" value))
               'face 'cider-result-overlay-face)
   props))

(defconst cider--fringe-arrow-string
  #("." 0 1 (display (left-fringe right-triangle)))
  "Used as an overlay's before-string prop to place a fringe arrow.")

(defun cider--debug-display-result-overlay (value)
  "Place an overlay at point displaying VALUE."
  (when cider-debug-use-overlays
    ;; This is cosmetic, let's ensure it doesn't break the session no matter what.
    (ignore-errors
      (remove-overlays nil nil 'cider-type 'debug-result)
      (remove-overlays nil nil 'cider-type 'debug-code)
      ;; Result
      (cider--make-result-overlay value 'debug-result cider-debug-use-overlays
                                  'before-string cider--fringe-arrow-string)
      ;; Code
      (cider--make-overlay (save-excursion (forward-sexp -1) (point))
                           (point) 'debug-code
                           'face 'cider-debug-code-overlay-face
                           ;; Higher priority than `show-paren'.
                           'priority 2000))))


;;; Movement logic
(defun cider--forward-sexp (n)
  "Move forward N logical sexps.
This will skip over sexps that don't represent objects, such as ^{}."
  (while (> n 0)
    ;; Non-logical sexps.
    (while (progn (forward-sexp 1)
                  (forward-sexp -1)
                  (looking-at-p "\\^"))
      (forward-sexp 1))
    ;; The actual sexp
    (forward-sexp 1)
    (setq n (1- n))))

(defun cider--debug-move-point (file pos coordinates)
  "Place point on POS in FILE, then navigate into the next sexp.
COORDINATES is a list of integers that specify how to navigate into the
sexp."
  ;; Navigate to the instrumented sexp, wherever we might be.
  (find-file file)
  ;; Position of the sexp.
  (goto-char pos)
  (condition-case nil
      ;; Make sure it is a list.
      ;; Navigate through sexps inside the sexp.
      (progn
        (while coordinates
          (down-list)
          (cider--forward-sexp (pop coordinates)))
        ;; Place point at the end of instrumented sexp.
        (cider--forward-sexp 1))
    ;; Avoid throwing actual errors, since this happens on every breakpoint.
    (error (message "Can't find instrumented sexp, did you edit the source?"))))

(defun cider--handle-debug (response)
  "Handle debugging notification.
RESPONSE is a message received from the nrepl describing the input
needed. It is expected to contain at least \"key\", \"input-type\", and
\"prompt\", and possibly other entries depending on the input-type."
  (nrepl-dbind-response response (debug-value key coor filename point input-type prompt locals)
    (let ((input))
      (unwind-protect
          (setq input
                (pcase input-type
                  ("expression" (cider-read-from-minibuffer
                                 (or prompt "Expression: ")))
                  ((pred sequencep)
                   (when (and filename point)
                     (cider--debug-move-point filename point coor))
                   (cider--debug-display-result-overlay debug-value)
                   (cider--debug-read-command input-type debug-value prompt locals))))
        ;; No matter what, we want to send this request or the session will stay
        ;; hanged.
        (nrepl-send-request
         (list "op" "debug-input" "key" key
               ;; If the user somehow managed to trigger an error or not input
               ;; anything send :quit to avoid getting an exception.
               "input" (or input ":quit"))
         #'ignore)))))

(defvar cider--debug-display-locals nil
  "If non-nil, local variables are displayed while debugging.
Can be toggled while debugging with `l'.")

(defun cider--debug-format-locals-list (locals)
  "Return a string description of list LOCALS.
Each element of LOCALS should be a list of at least two elements."
  (if locals
      (let ((left-col-width
             ;; To right-indent the variable names.
             (apply #'max (mapcar (lambda (l) (string-width (car l))) locals))))
        ;; A format string to build a format string. :-P
        (mapconcat (lambda (l) (format (format "%%%ds: %%s\n" left-col-width)
                            (propertize (car l) 'face 'font-lock-variable-name-face)
                            (cider-font-lock-as-clojure (cadr l))))
                   locals ""))
    ""))

(defun cider--debug-read-command (command-list value prompt locals)
  "Receive input from the user representing a command to do.
VALUE is displayed to the user as the output of last evaluated sexp."
  (let* ((prompt (concat (when cider--debug-display-locals
                           (cider--debug-format-locals-list locals))
                         prompt))
         (cider-interactive-eval-result-prefix (concat prompt " (l)ocals\n => ")))
    (cider--display-interactive-eval-result (or value "#unknown#")))
  (let ((alist `((?\C-\[ . ":quit") (?\C-g  . ":quit")
                 ,@(mapcar (lambda (k) (cons (string-to-char k) (concat ":" k)))
                           command-list)))
        (input (read-char)))
    (pcase input
      (?l (setq cider--debug-display-locals (not cider--debug-display-locals))
          (cider--debug-read-command command-list value prompt locals))
      (_ (or (cdr (assq input alist))
             (cider--debug-read-command command-list value prompt locals))))))


;;; User commands
;;;###autoload
(defun cider-debug-defun-at-point ()
  "Instrument the top-level expression at point.
If it is a defn, dispatch the instrumented definition.  Otherwise,
immediately evaluate the instrumented expression.

While debugged code is being evaluated, the user is taken through the
source code and displayed the value of various expressions.  At each step,
a number of keys will be prompted to the user."
  (interactive)
  (cider--debug-init-connection)
  (let* ((expression (cider-defun-at-point))
         (eval-buffer (current-buffer))
         (position (cider-defun-at-point-start-pos))
         (prefix
          (if (string-match-p "\\`(defn-? " expression)
              "Instrumented => " "=> "))
         (instrumented (format cider--instrument-format
                         (buffer-file-name)
                         position
                         expression)))
    ;; Once the code has been instrumented, it can be sent as a
    ;; regular evaluation. Any debug messages will be received by the
    ;; callback specified in `cider--debug-init-connection'.
    (cider-interactive-eval
     instrumented
     (nrepl-make-response-handler (current-buffer)
                                  (lambda (_buffer value)
                                    (let ((cider-interactive-eval-result-prefix prefix))
                                      (cider--display-interactive-eval-result value)))
                                  ;; Below is the default for `cider-interactive-eval'.
                                  (lambda (_buffer out)
                                    (cider-emit-interactive-eval-output out))
                                  (lambda (_buffer err)
                                    (cider-emit-interactive-eval-err-output err)
                                    (cider-handle-compilation-errors err eval-buffer))
                                  '()))))

(provide 'cider-debug)
;;; cider-debug.el ends here
