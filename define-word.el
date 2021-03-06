;;; define-word.el --- display the definition of word at point. -*- lexical-binding: t -*-

;; Copyright (C) 2015 Oleh Krehel

;; Author: Oleh Krehel <ohwoeowho@gmail.com>
;; URL: https://github.com/abo-abo/define-word
;; Version: 0.1.0
;; Package-Requires: ((emacs "24.3"))
;; Keywords: dictionary, convenience

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This package will send an anonymous request to https://wordnik.com/
;; to get the definition of word or phrase at point, parse the resulting HTML
;; page, and display it with `message'.
;;
;; Extra services can be added by customizing `define-word-services'
;; where an url, a parsing function, and an (optional) function other
;; than `message' to display the results can be defined.
;;
;; The HTML page is retrieved asynchronously, using `url-retrieve-link'.
;;
;;; Code:

(require 'url-parse)
(require 'url-http)
(require 'nxml-mode)

(defgroup define-word nil
  "Define word at point using an online dictionary."
  :group 'convenience
  :prefix "define-word-")

(defvar define-word-limit 10
  "Maximum amount of results to display.")

(defcustom define-word-displayfn-alist nil
  "Alist for display functions per service.
By default, `message' is used."
  :type '(alist
          :key-type (symbol :tag "Name of service")
          :value-type (function :tag "Display function")))

(defun define-word-displayfn (service)
  "Return the display function for SERVICE."
  (or (cdr (assoc service define-word-displayfn-alist))
      #'message))

(defcustom define-word-services
  '((wordnik "http://wordnik.com/words/%s" define-word--parse-wordnik)
    (openthesaurus "https://www.openthesaurus.de/synonyme/%s" define-word--parse-openthesaurus)
    (webster "http://webstersdictionary1828.com/Dictionary/%s" define-word--parse-webster)
    (frdic "http://www.frdic.com/dicts/fr/%s" define-word--parse-frdic)
    (larousse "https://www.larousse.fr/dictionnaires/francais/%s" define-word--parse-larousse))
  "Services for define-word, A list of lists of the
  format (symbol url function-for-parsing).
Instead of an url string, url can be a custom function for retrieving results."
  :type '(alist
          :key-type (symbol :tag "Name of service")
          :value-type (group
                       (string :tag "Url (%s denotes search word)")
                       (function :tag "Parsing function"))))

(defcustom define-word-default-service 'wordnik
  "The default service for define-word commands. Must be one of
  `define-word-services'"
  :type 'symbol)

(defun define-word--to-string (word service)
  "Get definition of WORD from SERVICE."
  (let* ((servicedata (assoc service define-word-services))
         (retriever (nth 1 servicedata))
         (parser (nth 2 servicedata)))
    (if (functionp retriever)
        (funcall retriever word)
      ;; adapted `url-insert-file-contents'
      (let* ((url (format retriever (downcase word)))
             (buffer (url-retrieve-synchronously url t t)))
        (with-temp-buffer
          (url-insert-buffer-contents buffer url)
          (funcall parser))))))

(defun define-word--expand (regex definition service)
  (let ((case-fold-search nil))
    (when (string-match regex definition)
      (concat
       definition
       "\n" (match-string 1 definition) ":\n"
       (mapconcat (lambda (s) (concat "  " s))
                  (split-string
                   (define-word--to-string (match-string 1 definition) service)
                   "\n")
                  "\n")))))

;;;###autoload
(defun define-word (word service &optional choose-service)
  "Define WORD using various services.

By default uses `define-word-default-service', but a prefix arg
lets the user choose service."
  (interactive "MWord: \ni\nP")
  (let* ((service (or service
                      (if choose-service
                          (intern
                           (completing-read
                            "Service: " define-word-services))
                        define-word-default-service)))
         (results (define-word--to-string word service)))

    (funcall
     (define-word-displayfn service)
     (cond ((not results)
            "0 definitions found")
           ((define-word--expand "Plural form of \\(.*\\)\\.$" results service))
           ((define-word--expand "Past participle of \\(.*\\)\\.$" results service))
           ((define-word--expand "Present participle of \\(.*\\)\\.$" results service))
           (t
            results)))))

;;;###autoload
(defun define-word-at-point (arg &optional service)
  "Use `define-word' to define word at point.
When the region is active, define the marked phrase.
Prefix ARG lets you choose service.

In a non-interactive call SERVICE can be passed."
  (interactive "P")
  (if (use-region-p)
      (define-word
          (buffer-substring-no-properties
           (region-beginning)
           (region-end))
          service arg)
    (define-word (substring-no-properties
                  (thing-at-point 'word))
        service arg)))

(defface define-word-face-1
  '((t :inherit font-lock-keyword-face))
  "Face for the part of speech of the definition.")

(defface define-word-face-2
  '((t :inherit default))
  "Face for the body of the definition")

(defface define-word-face-3
  '((t (:inherit font-lock-comment-face :foreground "aquamarine")))
  "Face for the example of the definition")

(defun define-word--join-results (results)
  (mapconcat
   #'identity
   (if (> (length results) define-word-limit)
       (cl-subseq results 0 define-word-limit)
     results)
   "\n"))

(defun define-word--regexp-to-face (regexp face)
  (goto-char (point-min))
  (while (re-search-forward regexp nil t)
    (let ((match (match-string 1)))
      (replace-match
       (propertize match 'face face)))))

(defconst define-word--tag-faces
  '(("<\\(?:em\\|i\\)>\\(.*?\\)</\\(?:em\\|i\\)>" italic)
    ("<xref>\\(.*?\\)</xref>" link)
    ("<strong>\\(.*?\\)</strong>" bold)
    ("<internalXref.*?>\\(.*?\\)</internalXref>" default)
    ("<sup>\\(.*?\\)</sup>" superscript)
    ("<sub>\\(.*?\\)</sub>" subscript)))

(defun define-word--convert-html-tag-to-face (str)
  "Replace semantical HTML markup in STR with the relevant faces."
  (with-temp-buffer
    (insert str)
    (cl-loop for (regexp face) in define-word--tag-faces do
	     (define-word--regexp-to-face regexp face))
    (buffer-string)))

(defun define-word-html-entities-to-unicode (string)
  (let* ((plist '(Aacute "Á" aacute "á" Acirc "Â" acirc "â" acute "´" AElig "Æ" aelig "æ" Agrave "À" agrave "à" alefsym "ℵ" Alpha "Α" alpha "α" amp "&" and "∧" ang "∠" apos "'" aring "å" Aring "Å" asymp "≈" atilde "ã" Atilde "Ã" auml "ä" Auml "Ä" bdquo "„" Beta "Β" beta "β" brvbar "¦" bull "•" cap "∩" ccedil "ç" Ccedil "Ç" cedil "¸" cent "¢" Chi "Χ" chi "χ" circ "ˆ" clubs "♣" cong "≅" copy "©" crarr "↵" cup "∪" curren "¤" Dagger "‡" dagger "†" darr "↓" dArr "⇓" deg "°" Delta "Δ" delta "δ" diams "♦" divide "÷" eacute "é" Eacute "É" ecirc "ê" Ecirc "Ê" egrave "è" Egrave "È" empty "∅" emsp " " ensp " " Epsilon "Ε" epsilon "ε" equiv "≡" Eta "Η" eta "η" eth "ð" ETH "Ð" euml "ë" Euml "Ë" euro "€" exist "∃" fnof "ƒ" forall "∀" frac12 "½" frac14 "¼" frac34 "¾" frasl "⁄" Gamma "Γ" gamma "γ" ge "≥" gt ">" harr "↔" hArr "⇔" hearts "♥" hellip "…" iacute "í" Iacute "Í" icirc "î" Icirc "Î" iexcl "¡" igrave "ì" Igrave "Ì" image "ℑ" infin "∞" int "∫" Iota "Ι" iota "ι" iquest "¿" isin "∈" iuml "ï" Iuml "Ï" Kappa "Κ" kappa "κ" Lambda "Λ" lambda "λ" lang "〈" laquo "«" larr "←" lArr "⇐" lceil "⌈" ldquo "“" le "≤" lfloor "⌊" lowast "∗" loz "◊" lrm "" lsaquo "‹" lsquo "‘" lt "<" macr "¯" mdash "—" micro "µ" middot "·" minus "−" Mu "Μ" mu "μ" nabla "∇" nbsp "" ndash "–" ne "≠" ni "∋" not "¬" notin "∉" nsub "⊄" ntilde "ñ" Ntilde "Ñ" Nu "Ν" nu "ν" oacute "ó" Oacute "Ó" ocirc "ô" Ocirc "Ô" OElig "Œ" oelig "œ" ograve "ò" Ograve "Ò" oline "‾" omega "ω" Omega "Ω" Omicron "Ο" omicron "ο" oplus "⊕" or "∨" ordf "ª" ordm "º" oslash "ø" Oslash "Ø" otilde "õ" Otilde "Õ" otimes "⊗" ouml "ö" Ouml "Ö" para "¶" part "∂" permil "‰" perp "⊥" Phi "Φ" phi "φ" Pi "Π" pi "π" piv "ϖ" plusmn "±" pound "£" Prime "″" prime "′" prod "∏" prop "∝" Psi "Ψ" psi "ψ" quot "\"" radic "√" rang "〉" raquo "»" rarr "→" rArr "⇒" rceil "⌉" rdquo "”" real "ℜ" reg "®" rfloor "⌋" Rho "Ρ" rho "ρ" rlm "" rsaquo "›" rsquo "’" sbquo "‚" scaron "š" Scaron "Š" sdot "⋅" sect "§" shy "" Sigma "Σ" sigma "σ" sigmaf "ς" sim "∼" spades "♠" sub "⊂" sube "⊆" sum "∑" sup "⊃" sup1 "¹" sup2 "²" sup3 "³" supe "⊇" szlig "ß" Tau "Τ" tau "τ" there4 "∴" Theta "Θ" theta "θ" thetasym "ϑ" thinsp " " thorn "þ" THORN "Þ" tilde "˜" times "×" trade "™" uacute "ú" Uacute "Ú" uarr "↑" uArr "⇑" ucirc "û" Ucirc "Û" ugrave "ù" Ugrave "Ù" uml "¨" upsih "ϒ" Upsilon "Υ" upsilon "υ" uuml "ü" Uuml "Ü" weierp "℘" Xi "Ξ" xi "ξ" yacute "ý" Yacute "Ý" yen "¥" yuml "ÿ" Yuml "Ÿ" Zeta "Ζ" zeta "ζ" zwj "" zwnj ""))
	 (get-function (lambda (s) (or (plist-get plist (intern (substring s 1 -1))) s))))
    (replace-regexp-in-string "&[^; ]*;" get-function string))) 

(defun define-word--select-service ()
  (interactive)
  (let ((target (completing-read "define-word services: " (mapcar #'car define-word-services))))
    (setq define-word-default-service (intern target))))

(defun define-word--parse-wordnik ()
  "Parse output from wordnik site and return formatted list"
  (save-match-data
    (let (results beg part)
      (while (re-search-forward "<li><abbr[^>]*>\\([^<]*\\)</abbr>" nil t)
        (setq part (match-string 1))
        (unless (= 0 (length part))
          (setq part (concat part " ")))
        (skip-chars-forward " ")
        (setq beg (point))
        (when (re-search-forward "</li>")
          (push (concat (propertize part 'face 'define-word-face-1)
                        (propertize
                         (buffer-substring-no-properties beg (match-beginning 0))
                         'face 'define-word-face-2))
                results)))
      (when (setq results (nreverse results))
        (define-word--convert-html-tag-to-face (define-word--join-results results))))))

(defun define-word--parse-webster ()
  "Parse definition from webstersdictionary1828.com."
  (save-match-data
    (goto-char (point-min))
    (let (results def-type)
      (while (re-search-forward "<p><strong>\\(?:[[:digit:]]\\.\\)?.*</strong>\\(.*?\\)</p>" nil t)
        (save-match-data
          (save-excursion
            (re-search-backward "<p><strong>[A-Z'.]*</strong>, <em>\\(.*?\\)</em>")
            (let ((match (match-string 1)))
              (setq def-type
                    (cond
                      ((equal match "adjective") "adj.")
                      ((equal match "noun") "n.")
                      ((equal match "verb intransitive") "v.")
                      ((equal match "verb transitive") "vt.")
                      (t ""))))))
        (push
         (concat
          (propertize def-type 'face 'bold)
          (define-word--convert-html-tag-to-face (match-string 1)))
         results))
      (when (setq results (nreverse results))
        (define-word--join-results results)))))

(defun define-word--parse-openthesaurus ()
  "Parse output from openthesaurus site and return formatted list"
  (save-match-data
    (let (results part beg)
      (goto-char (point-min))
      (nxml-mode)
      (while (re-search-forward "<sup>" nil t)
        (goto-char (match-beginning 0))
        (setq beg (point))
        (nxml-forward-element)
        (delete-region beg (point)))
      (goto-char (point-min))
      (while (re-search-forward
              "<span class='wiktionaryItem'> [0-9]+.</span>\\([^<]+\\)<" nil t)
        (setq part (match-string 1))
        (backward-char)
        (push (string-trim part) results))
      (when (setq results (nreverse results))
        (define-word--join-results results)))))

(defun define-word--parse-larousse ()
  "Parse output from larousse site and return formatted list"
  (save-match-data
    (let (results part)
      (when (re-search-forward "<p class=\"CatgramDefinition\">\\([^<]*\\)" nil t)
	(setq part (propertize (match-string 1) 'face 'define-word-face-1))) 
      (push part results)
      (while (re-search-forward "<li class=\"DivisionDefinition\">\\([^<]*\\)" nil t)
	(let (entry)
	  (push (propertize
		 (concat "- " (substring-no-properties (define-word-html-entities-to-unicode (match-string 1))))
		 'face 'define-word-face-2)
		entry)
	  (while (re-search-forward "<span class=\"ExempleDefinition\">\\([^<]*\\)" nil t)
	    (push (propertize (define-word-html-entities-to-unicode (match-string 1)) 'face 'define-word-face-3) entry))
	  (push (string-join (nreverse entry) " ") results)))
      (when (setq results (nreverse results))
	(define-word--convert-html-tag-to-face (define-word--join-results results))))))

(defun define-word--parse-frdic ()
  "Parse output from frdic site and return formatted list"
  (save-match-data
    (let (results part)
      (while (re-search-forward "<span class=cara>\\([^<]*\\)</span>" nil t)
	(setq part (match-string 1))
	(unless (= 0 (length part))
	  (setq part (concat part " ")))
	(when (re-search-forward "<span class=exp>\\([^<]*\\)</span>" nil t)
	  (push (concat (propertize part 'face 'define-word-face-1)
			(propertize
			 (substring-no-properties (match-string 1))
			 'face 'define-word-face-2))
		results)))
      (when (setq results (nreverse results))
	(define-word--convert-html-tag-to-face (define-word--join-results results))))))

(provide 'define-word)

;;; define-word.el ends here
