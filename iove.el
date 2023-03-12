;;; iove.el --- inline code annotationss with values of specified variables.

;; Copyright (C) 2023 Eugene Tagin

;; Author: Eugene Tagin <evjava@yandex.ru>
;; Created: 12 Mar 2023
;; Package-Requires: ((emacs "24.3") (bind-key "2.4"))
;; Keywords: inline annotations overlays python
;; URL: https://github.com/evjava/iove

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

(require 'json)
(require 'org)

;; constants

(setq iove/comment-printer-pref "##")
(setq iove/macro-action-sep ">")
(setq iove/code-suffix "")
(setq iove/enabled nil)
(setq iove/sleep-period 0.08)
(setq iove/image-overlay-width 200)
(setq iove/annotate-color "#5dbb63")
(setq iove/error-color "#ff6347")
(setq iove/svg-counter 1)

;; utils

(defun iove/replace-current-line (new-line)
  " without '\n' "
  (beginning-of-line)
  (insert new-line)
  (kill-line nil))

(defun iove/apply-to-current-line (line-callback)
  " passes line without last '\n', replaces it if callback returns non-nil "
  (let* ((line-0 (substring-no-properties (thing-at-point 'line)))
         (line (substring line-0 0 (1- (length line-0))))
         (line-patched (funcall line-callback line)))
    (when line-patched
      (iove/replace-current-line line-patched))))

(defun iove/buffer-content ()
  (buffer-substring-no-properties (point-min) (point-max)))

(defun iove/spaces (count)
  (s-join "" (cl-loop for i from 1 to count collect " ")))

(defun iove/shift-text (text indent)
  (let* ((lines (s-split "\n" text))
         (ind (iove/spaces indent))
         (lines-ind (--map (s-concat ind it) lines))
         (res (s-join "\n" lines-ind))
         ) res))

(defun iove/split-at-first-sexp (print-macro)
  " todo: generalize and move to utils "
  (with-temp-buffer
    (insert print-macro)
    (beginning-of-buffer)
    (forward-sexp 1)
    (cons (buffer-substring-no-properties 1 (point))
          (buffer-substring-no-properties (1+ (point)) (point-max)))))

(defun iove/s-split-trim (separator s)
  (let* ((parts (s-split separator s))
         (res (-map #'s-trim parts))
         ) res))

(defun iove/nullify-empty (e)
  (when (not (empty e)) e))

(defun iove/extract-last-comint-section ()
  (save-excursion
    (end-of-buffer)
    (backward-char 1)
    (beginning-of-line)
    (backward-char 1)
    (let* ((log-end (point))
           (log-start (save-excursion (comint-previous-prompt 1) (1+ (point))))
           (res (buffer-substring-no-properties log-start log-end))
           ) res)))

(defun iove/parse-py-basic-list (py-list)
  (--> py-list
       (substring it 1 (1- (length it)))
       (s-replace "," "" it)
       (s-concat "(" it ")")
       (read it)))

(defun iove/make-dot-props ()
  " Makes color properties for dot "
  (let* ((dot-background (iove/get-dot-background))
         (text (face-attribute 'default :foreground))
         (fmt "ratio=1; bgcolor=\"%s\"; node [color=\"%s\", fontcolor=\"%s\"]; edge[color=\"%s\"]; ")
         (res (format fmt dot-background text text text))
         ) res))

(defun iove/edges-to-dot (edges is-directed)
  (let* ((prefix (if is-directed "digraph { " "graph { "))
         (suffix " }")
         (e-sep (if is-directed "->" "--"))
         (s-edges (--map (format "%d %s %d" (car it) e-sep (cadr it)) edges))
         (graph (s-concat prefix (iove/make-dot-props) (s-join "; " s-edges) suffix))
         ) graph))

(defun iove/edges-to-image (edges is-directed)
  (let* ((graph (iove/edges-to-dot edges is-directed))
         (fname (format "/tmp/g-%03d.svg" iove/svg-counter))
         (cmd (format "echo '%s' | dot -Tsvg > %s" graph fname)))
    (shell-command-to-string cmd)
    (setq iove/svg-counter (1+ iove/svg-counter))
    fname))

(defun iove/show-overlay (text start end color)
  (let* ((ov (make-overlay start end)))
    (overlay-put ov 'face `(:foreground ,color))
    (overlay-put ov 'display text)))

(defun iove/show-image-overlay (image-fname start end)
  (if (= 0 (file-attribute-size (file-attributes image-fname)))
      (iove/show-overlay
       (format "Bad image ( %s ), can't show..." image-fname)
       start end iove/error-color)
    (let* ((ov (make-overlay start end))
           (w iove/image-overlay-width)
           (image (org--create-inline-image image-fname w)))
      (overlay-put ov 'display image)
      )))

(defun iove/modify-color (color is-darker)
  " Modify the color by making it either darker or lighter.
    COLOR is a string representing the color in hexadecimal format, e.g. \"#a1bf03\".
    If IS-DARKER is t, the new color will be darker. If IS-DARKER is nil, the new color will be lighter.
  "
  (let ((factor (if is-darker 0.9 1.3)))
    (cl-flet ((modify-component (c) (max 0 (min 255 (floor (* factor c 256))))))
      (let* ((components (color-name-to-rgb color))
             (components-upd (mapcar #'modify-component components))
             (format-args (cons "#%02x%02x%02x" components-upd))
             (res (apply #'format format-args))
             ) res))))

(defun iove/is-dark-mode ()
  (let* ((background (face-attribute 'default :background))
         (components (color-name-to-rgb background))
         (c-sum (apply #'+ components))
         (is-dark (< c-sum 1.5))
         ) is-dark))

(defun iove/get-dot-background ()
  (let* ((background (face-attribute 'default :background))
         (is-dark (iove/is-dark-mode))
         (background-fix (iove/modify-color background (not is-dark)))
         ) background-fix))

(defun iove/expand-print-macro (num print-macro &optional action)
  (let* ((macro-parts (if (s-starts-with? "?" print-macro)
                          (iove/split-at-first-sexp (substring print-macro 1))
                        (cons nil print-macro)))
         (macro-parts-a (car macro-parts))
         (macro-parts-b (cdr macro-parts))
         (if-part (if macro-parts-a (format "if %s: " macro-parts-a) ""))
         (p-vars (s-split " " macro-parts-b))
         (prop-vars (s-join " " (--map (format "\"%s\" \"{%s}\"" it it) p-vars)))
         (print-part (if (null action)
                         (format "print(f'(:num %d :asgn (%s))')" num prop-vars)
                       (format "print(f'(:num %d :asgn (%s) :action %s)')" num prop-vars action)))
         (res (s-concat if-part print-part))
         ) res))

(defun iove/extract-lvals (code line)
  (unless (s-contains? " = " code)
    (error "Assignment for line <%s> expected, found: %s" line code))
  (->> code (s-split " = ") (car) (s-replace "," "") (s-trim)))

(defun iove/expand-line (num line)
  (when (s-contains? iove/comment-printer-pref line)
    (pcase-let*
        ((`(,code ,macro) (s-split iove/comment-printer-pref line))
         (`(,macro-pref-0 ,macro-suf) (iove/s-split-trim iove/macro-action-sep macro))
         (macro-pref (if (empty macro-pref-0) (iove/extract-lvals code line) macro-pref-0))
         (macro-expanded (iove/expand-print-macro num macro-pref (iove/nullify-empty macro-suf)))
         (res (if (empty (s-trim code))
                  (s-concat code macro-expanded)
                (s-concat code "; " macro-expanded)))
         ) res)))

(defun iove/patch-code ()
  (unless (null (buffer-file-name))
    (error "Should be temporary file! Found: %s" (buffer-file-name)))
  (beginning-of-buffer)
  (while (search-forward iove/comment-printer-pref nil t 1)
    (iove/apply-to-current-line
     (lambda (line) (iove/expand-line (line-number-at-pos) line))))
  (beginning-of-buffer)
  (replace-string "#! " ""))

(defun iove/patch-and-eval (py-code)
  (unless (python-shell-get-process) (run-python))
  (with-temp-buffer
    (insert (s-concat py-code "\n" iove/code-suffix))
    (iove/patch-code)
    (message "Going to eval: [\n%s\n]" (iove/buffer-content))
    (python-shell-send-buffer)))

(defun iove/comm-printer-pos (num)
  " returns positions list: {beginning-of-line, beginning-of-code, end-of-line} "
  (let* ((_ (goto-line num))
         (pos-0 (progn (beginning-of-line) (point)))
         (pos-a (progn (search-forward iove/comment-printer-pref nil t 1) (point)))
         (pos-b (progn (end-of-line) (point)))
         (lnk (length iove/comment-printer-pref))
         (res (list pos-0 (- pos-a lnk) pos-b))
         ) res))

(defun iove/asgn-extract-values (asgn)
  (let* ((pairs (-partition 2 asgn))
         (res (--map (cadr it) pairs))
         ) res))

(defun iove/asgns-format-one (asgns)
  (let* ((asgn (car asgns))
         (pair-values (-partition 2 asgn))
         (fmt-values (--map (s-concat (car it) ": " (cadr it)) pair-values))
         (annot (s-concat "## " (s-join ", " fmt-values)))
         ) annot))

(defun iove/asgns-format-many (asgns)
  (let* ((asgn-0 (car asgns))
         (vars (-map #'car (-partition 2 asgn-0)))
         (values-all (--map (iove/asgn-extract-values it) asgns))
         (tbl-raw (cons vars (cons 'hline values-all)))
         (tbl-pretty (orgtbl-to-orgtbl tbl-raw nil))
         ) tbl-pretty))

(defun iove/asgns-format (asgns)
  (cond
   ((= 1 (length asgns)) (iove/asgns-format-one asgns))
   (t                    (iove/asgns-format-many asgns))))

(defun iove/parse-error (py-log)
  (when (s-contains? "Traceback (" py-log)
    (with-temp-buffer
      (let* ((_ (insert py-log))
             (line-err (s-trim (thing-at-point 'line)))
             (_ (search-backward ", line "))
             (_ (forward-word 1))
             (_ (forward-char 1))
             (num (thing-at-point 'number))
             (res `(:num ,num :text ,line-err))
           ) res))))
             
(defun iove/extract-one-value (asgn)
  (unless (= 2 (length asgn)) (error "Graph only for single var"))
  (cadr asgn))

(defun iove/extract-edges-and-draw (num asgn is-directed)
  " returns fname with graph drawn by graphviz "
  (let* ((py-edges (iove/extract-one-value asgn))
         (edges (iove/parse-py-basic-list py-edges))
         (fname (iove/edges-to-image edges is-directed))
         ) fname))

(defun iove/overlays-for-group (num-annots)
  (let* ((num (car num-annots))
         (annots (cdr num-annots))
         (action (or (plist-get (car annots) :action) :show))
         (asgns (--map (plist-get it :asgn) annots))
         (res-0 (pcase action
                  (:show    `(:tp :text  :prop ,(iove/asgns-format asgns)))
                  (:graph   `(:tp :image :prop ,(iove/extract-edges-and-draw num (car asgns) nil)))
                  (:digraph `(:tp :image :prop ,(iove/extract-edges-and-draw num (car asgns) t)))))
         (res (plist-put res-0 :num num))
         ) res))

(defun iove/parse-py-log (py-log)
  " extracts lines like \"(:num ...\" "
  (let* ((lines (s-split "\n" py-log))
         (annot-lines (--filter (s-starts-with? "(:num " it) lines))
         (annots-raw (-map #'read annot-lines))
         (annots-gr (--group-by (plist-get it :num) annots-raw))
         (overlays (-map #'iove/overlays-for-group annots-gr))
         (err (iove/parse-error py-log))
         (res `(:overlays ,overlays :error ,err))
         ) res))

(defun iove/overlay-apply-exception (overlay)
  " todo generalize with iove/comm-printer-pos and iove/overlay-apply "
  (let* ((num (plist-get overlay :num))
         (_ (goto-line num))
         (_ (beginning-of-line))
         (pb (point))
         (_ (back-to-indentation))
         (pi (point))
         (_ (end-of-line))
         (p (point))
         (_ (recenter-top-bottom))
         (ind (iove/spaces (- pi pb)))
         (text (s-concat "\n" ind (plist-get overlay :text) "\n"))
         (_ (iove/show-overlay text p (1+ p) iove/error-color))
         ) nil))

(defun iove/overlay-apply (overlay)
  (let* ((num (plist-get overlay :num))
         (cmt-pos (iove/comm-printer-pos num))
         (p-start (car cmt-pos))
         (p-com (cadr cmt-pos))
         (p-end (caddr cmt-pos))
         (ind (- p-com p-start))
         (_ (pcase (plist-get overlay :tp)
              (:text
               (let* ((text-0 (plist-get overlay :prop))
                      (text (if (not (s-starts-with? "|" text-0)) text-0
                              (s-replace "\n" (s-concat "\n" (iove/spaces ind)) text-0))))
                 (iove/show-overlay text p-com p-end iove/annotate-color)))
              (:image
               (let* ((i-fname (plist-get overlay :prop)))
                 (iove/show-image-overlay i-fname p-com p-end)))))
         ) nil))

(defun iove/extract-py-log ()
  (with-current-buffer "*Python*" (iove/extract-last-comint-section)))

(defun iove/annotate ()
  (interactive)
  (setq iove/enabled (not iove/enabled))
  (if (not iove/enabled) (remove-overlays)
    (let* ((bname (buffer-file-name))
           (py-code (iove/buffer-content))
           (_ (iove/patch-and-eval py-code))
           (_ (sleep-for iove/sleep-period))
           (py-log (iove/extract-py-log))
           (overlays-and-err (iove/parse-py-log py-log))
           (overlays (plist-get overlays-and-err :overlays))
           (err (plist-get overlays-and-err :error))
           (rev-overlays (reverse overlays)))
      (save-excursion
        (remove-overlays)
        (end-of-buffer)
        (mapc #'iove/overlay-apply rev-overlays))
      (when err
          (iove/overlay-apply-exception err))
      (message "Done! Added %d annotations!" (length rev-overlays)))))

(provide 'iove)
