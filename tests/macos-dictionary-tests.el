;;; macos-dictionary-tests.el --- Tests for macos-dictionary  -*- lexical-binding: t; -*-

(require 'ert)

(load (expand-file-name
       "../macos-dictionary.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defconst macos-dictionary-test--result
  '((word . "run")
    (dictionaries
     . (((name . "First Dictionary")
         (shortName . "First")
         (entries
          . (((headword . "run")
              (html . "<html><body><h2>run</h2><p><b>verb</b> move quickly; see <a href=\"x-dictionary:d:sprint\">sprint</a>.</p></body></html>")))))
        ((name . "Second Dictionary")
         (shortName . "Second")
         (entries
          . (((headword . "run")
              (html . "<html><body><h2>run</h2><p><i>noun</i> an act of running.</p></body></html>")))))))))

(defconst macos-dictionary-test--rich-html
  (concat
   "<html><head><base href=\"file:///tmp/Dictionary.dictionary/Contents/\">"
   "</head><body><d:entry><h1>semantic</h1>"
   "<div><h1 class=\"hword\">semantic</h1>"
   "<audio src=\"prons/semantic.mp3\"></audio>"
   "<img src=\"speaker.png\" onmousedown=\"audio.play()\">"
   "<ol><li><span class=\"num\">1</span> first meaning</li>"
   "<li><span class=\"num\">2</span> second meaning</li></ol>"
   "</div></d:entry></body></html>"))

(ert-deftest macos-dictionary-search-renders-all-rich-definitions ()
  (let ((buffer-name " *macos-dictionary-test*"))
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup)
                   (lambda (_word) macos-dictionary-test--result)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "run"))
            (with-current-buffer buffer-name
              (goto-char (point-min))
              (should (search-forward "First Dictionary" nil t))
              (should (search-forward "Second Dictionary" nil t))
              (goto-char (point-min))
              (should (search-forward "verb" nil t))
              (should (get-text-property (1- (point)) 'face))
              (should (search-forward "sprint" nil t))
              (should (equal (get-text-property (1- (point)) 'shr-url)
                             "x-dictionary:d:sprint")))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest macos-dictionary-links-search-for-the-linked-term ()
  (let (searched-word)
    (cl-letf (((symbol-function 'macos-dictionary-search)
               (lambda (word) (setq searched-word word))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (browse-url "x-dictionary:d:back%20up")))
    (should (equal searched-word "back up"))))

(ert-deftest macos-dictionary-mode-shows-key-hints-in-the-header-line ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (should header-line-format)
    (should (equal header-line-format
                   macos-dictionary-mode-header-line-format))
    (should (cl-find-if
             (lambda (item)
               (and (stringp item) (string-prefix-p ": WebKit" item)))
             header-line-format))))

(ert-deftest macos-dictionary-audio-links-use-the-audio-handler ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (should
     (eq (browse-url-select-handler
          "file:///tmp/Dictionary.dictionary/Contents/prons/semantic.mp3")
         #'macos-dictionary--play-audio))))

(ert-deftest macos-dictionary-audio-handler-plays-the-decoded-file ()
  (let (process-arguments)
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_file) t))
              ((symbol-function 'start-process)
               (lambda (&rest arguments)
                 (setq process-arguments arguments))))
      (macos-dictionary--play-audio
       "file:///tmp/Dictionary%20Name.dictionary/Contents/prons/semantic.mp3"))
    (should
     (equal process-arguments
            '("macos-dictionary-audio" nil "afplay"
              "/tmp/Dictionary Name.dictionary/Contents/prons/semantic.mp3")))))

(ert-deftest macos-dictionary-normalizes-dictionary-html ()
  (with-temp-buffer
    (macos-dictionary--insert-html macos-dictionary-test--rich-html)
    (let ((rendered (buffer-substring-no-properties (point-min) (point-max))))
      (should (= (how-many "semantic" (point-min) (point-max)) 1))
      (should-not (string-match-p "1 1" rendered))
      (should-not (string-match-p "2 2" rendered))
      (should (= (how-many "\\[audio\\]" (point-min) (point-max)) 1))
      (should-not (text-property-not-all
                   (point-min) (point-max) 'display nil)))
    (goto-char (point-min))
    (search-forward "semantic")
    (should (equal (get-text-property (1- (point)) 'macos-dictionary-html)
                   macos-dictionary-test--rich-html))))

(ert-deftest macos-dictionary-webkit-action-opens-the-entry-at-point ()
  (let (opened-html)
    (cl-letf (((symbol-function 'macos-dictionary--browse-html-in-webkit)
               (lambda (html) (setq opened-html html))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (let ((inhibit-read-only t))
          (macos-dictionary--insert-html macos-dictionary-test--rich-html))
        (goto-char (point-min))
        (search-forward "semantic")
        (macos-dictionary-view-in-webkit)))
    (should (equal opened-html macos-dictionary-test--rich-html))))

(ert-deftest macos-dictionary-webkit-view-uses-a-temporary-html-file ()
  (let ((webkit-buffer (generate-new-buffer " *macos-dictionary-webkit-test*"))
        opened-url
        opened-new-session
        temporary-file)
    (unwind-protect
        (cl-letf (((symbol-function 'xwidget-webkit-browse-url)
                   (lambda (url new-session)
                     (setq opened-url url
                           opened-new-session new-session)
                     (set-buffer webkit-buffer))))
          (save-current-buffer
            (macos-dictionary--browse-html-in-webkit
             macos-dictionary-test--rich-html))
          (with-current-buffer webkit-buffer
            (setq temporary-file macos-dictionary--webkit-temp-file)
            (should (equal (with-temp-buffer
                             (insert-file-contents temporary-file)
                             (buffer-string))
                           macos-dictionary-test--rich-html)))
          (should opened-new-session)
          (should (equal opened-url (browse-url-file-url temporary-file))))
      (when (buffer-live-p webkit-buffer)
        (kill-buffer webkit-buffer))
      (when (and temporary-file (file-exists-p temporary-file))
        (delete-file temporary-file)))
    (should-not (file-exists-p temporary-file))))

(provide 'macos-dictionary-tests)

;;; macos-dictionary-tests.el ends here
