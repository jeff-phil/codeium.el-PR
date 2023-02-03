;;; codeium.el --- codeium client for emacs         -*- lexical-binding: t; -*-

;; licence here

;;; Commentary:

;; currently you can install codeium binaries from https://github.com/Exafunction/codeium/releases/
;; set codeium-executable-loc to the location you installed the binaries
;; add codeium-completion-at-point to your completion-at-point-functions
;; you will be given a link to login

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)
;; removing this gives comp warnings, not sure why since its defined in url-http?
(eval-when-compile
	(defvar url-http-end-of-headers)
	(defvar url-http-response-status))

(defgroup codeium nil
	"codeium.el customization -some-doc-str-here-"
	:group 'convenience)
(defvar codeium-log-waiting-text (propertize "waiting for response" 'face '(:weight ultra-bold)))

(defvar codeium-fullpath-alist nil)

(eval-and-compile
	(defun codeium-default-func-name (symbol-name)
		(if (string-prefix-p "codeium" symbol-name)
			(concat "codeium-default" (substring symbol-name (length "codeium")))
			symbol-name)))
(defmacro codeium-def (name &rest args)
	(declare (doc-string 3))
	(pcase-let*
		(
			(doc-str) (value) (arglilst) (body)
			(
				(or
					`(,value)
					`(,value ,(and (pred stringp) doc-str))
					`(,arglist ,(and (pred stringp) doc-str) . ,body)
					`(,arglist . ,body)
					)
				args)
			(funcsymbol (when body (intern (codeium-default-func-name (symbol-name name)))))
			(value (or value `',funcsymbol))

			(fullpath
				(when (string-prefix-p "codeium/" (symbol-name name))
					(mapcar #'intern (cdr (split-string (symbol-name name) "/")))))
			(funcdefform (when body `((defun ,funcsymbol ,arglist ,@body))))

			(doc-str (or doc-str ""))
			)
		`(progn
			 (setf (alist-get ',name codeium-fullpath-alist) ',fullpath)
			 (defcustom ,name ,value
				 ;; i can probably process the doc-str
				 ,doc-str
				 :type 'sexp
				 :group 'codeium)
			 ,@funcdefform
			 ;; (setq ,name ,value)
			 )))


(codeium-def codeium-executable-loc (expand-file-name "codeium/codeium_language_server" user-emacs-directory)
	"path of your codeium executable")

(defconst codeium-apis
	'(GetCompletions Heartbeat CancelRequest GetAuthToken RegisterUser auth-redirect))

(codeium-def codeium-api-enabled (api) t)

(defvar codeium-fields-regexps
	`(
		 (GetCompletions .
			 ,(rx bol "codeium/" (or "metadata" "document" "editor_options") "/" (* anychar) eol))
		 (Heartbeat .
			 ,(rx bol "codeium/metadata/" (* anychar) eol))
		 (CancelRequest .
			 ,(rx bol "codeium/" (or (seq "metadata/" (* anychar)) "request_id")  eol))
		 (GetAuthToken)
		 (RegisterUser .
			 ,(rx bol "codeium/firebase_id_token" eol))
		 ))
(codeium-def codeium-api-fields (api)
	(let ((regexp (alist-get api codeium-fields-regexps)))
		(if (stringp regexp)
			(remq nil
				(mapcar
					(lambda (el)
						(when (string-match regexp (symbol-name (car el)))
							(car el)))
					codeium-fullpath-alist))
			nil)))

(defvar codeium-special-url-alist '((auth-redirect . "/auth")))
(codeium-def codeium-url (api state)
	(let ((endpoint
			  (or (alist-get api codeium-special-url-alist)
				  (concat "/exa.language_server_pb.LanguageServerService/" (symbol-name api)))))
		(url-parse-make-urlobj "http" nil nil "localhost" (codeium-state-port state)
			endpoint nil nil t)))


(codeium-def codeium/metadata/ide_name "emacs")
(codeium-def codeium/metadata/extension_version "1.1.32")
(codeium-def codeium/metadata/ide_version (emacs-version))
;; (codeium-def codeium/metadata/request_id (api)
;; 	(when (eq api 'GetCompletions)
;; 		(random most-positive-fixnum)))

(defvar global_requestid_counter 0)
(codeium-def codeium/metadata/request_id (api state)
	(when (eq api 'GetCompletions)
		(cl-incf global_requestid_counter)))
;; ;; (when (eq api 'GetCompletions)
;; ;; 	(setf (get state 'last-request-id) (or (get state 'last-request-id) 1))
;; ;; 	(get state 'last-request-id))))

;; for CancelRequest
(codeium-def codeium/request_id (api state val) val)

;; alternative getting key from file?
;; TODO
;; (setq codeium/metadata/api_key 'codeium-default/metadata/api_key)
(defun codeium-get-saved-api-key ())
(codeium-def codeium/metadata/api_key (api state)
	(if-let ((api-key (or (codeium-state-last-api-key state) (codeium-get-saved-api-key))))
		(setq codeium/metadata/api_key api-key)
		(setq codeium/metadata/api_key
			(lambda (api state)
				(when-let ((api-key (codeium-state-last-api-key state)))
					(setq codeium/metadata/api_key api-key))))
		nil))


(codeium-def codeium/document/text ()
	(buffer-string))
(codeium-def codeium/document/cursor_offset ()
	(codeium-utf8-byte-length (buffer-substring-no-properties (point-min) (point))))

(codeium-def codeium/document/editor_language () (symbol-name major-mode))

(defvar codeium-language-alist
	'(
		 (nil . 0)
		 (text-mode . 30)
		 (python-mode . 33)
		 (lisp-data-mode . 60)
		 ))
(codeium-def codeium/document/language ()
	(let ((mode major-mode))
		(while (not (alist-get mode codeium-language-alist))
			(setq mode (get mode 'derived-mode-parent)))
		(alist-get mode codeium-language-alist)))

(codeium-def codeium/document/line_ending "\n"
	"according to https://www.reddit.com/r/emacs/comments/5b7o9r/elisp_how_to_concat_newline_into_string_regarding/
	this can be always \\n")

(codeium-def codeium/editor_options/tab_size ()
	tab-width)
(codeium-def codeium/editor_options/insert_spaces ()
	(if indent-tabs-mode :false t))

(codeium-def codeium/firebase_id_token (api state) (codeium-state-last-auth-token state))


(cl-defstruct
	(codeium-state
		(:constructor codeium-state-make)
		(:copier nil))
	(name "")
	config
	proc
	buf
	fixed-port
	port
	port-ready-callback-list
	background-process-cancel-fn

	last-auth-token
	last-api-key

	(last-request-id 0)
	;; these has distinct elements
	(results-table (make-hash-table :test 'eql :weakness nil)) ; results that are ready
	(pending-table (make-hash-table :test 'eql :weakness nil)) ; requestid that we are waiting for
	)


(defvar codeium-state (codeium-state-make :name "default"))

;; (defun codeium-state-set-config (state field value)
;; 	(if (alist-get field csodeium-fullpath-alist)
;; 		(setf (alist-get field (codeium-state-config state)) value)
;; 		(error "%s is not a defined codeium config" field)
;; 		)
;; 	)


(defun codeium-get-config (field api state &optional given-val)
	(let*
		((val
			 (if (eq (alist-get field (codeium-state-config state) 'noexist) 'noexist)
				 (symbol-value field)
				 (alist-get field (codeium-state-config state)))))
		(if (functionp val)
			(cl-case (cdr (func-arity val))
				(0 (funcall val))
				(1 (funcall val api))
				(2 (funcall val api state))
				(t (funcall val api state given-val)))
			val)))

(defun codeium-nested-alist-get-multi (body top &rest rest)
	(if rest
		(apply #'codeium-nested-alist-get-multi (alist-get top body) rest)
		(alist-get top body)))
(defun codeium-nested-alist-set-multi (body val top &rest rest)
	(let ((cur-alist body))
		(setf (alist-get top cur-alist)
			(if rest
				(apply #'codeium-nested-alist-set-multi (alist-get top cur-alist) val rest)
				val))
		cur-alist))
(defun codeium-nested-alist-get (body field) 
	(let ((fullpath (alist-get field codeium-fullpath-alist)))
		(unless fullpath (error "field %s is set to path %s which is not valid" field fullpath))
		(apply #'codeium-nested-alist-get-multi body fullpath)))
(defun codeium--nested-alist-set (body field val) 
	(let ((fullpath (alist-get field codeium-fullpath-alist)))
		(unless fullpath (error "field %s is set to path %s which is not valid" field fullpath))
		(apply #'codeium-nested-alist-set-multi body val fullpath)))
(gv-define-expander codeium-nested-alist-get
	(lambda (do body field)
		(gv-letplace (getter setter) body
			(macroexp-let2 nil field field
				(funcall do `(codeium-nested-alist-get ,getter ,field)
					(lambda (v)
						(macroexp-let2 nil v v
							`(progn
								 ,(funcall setter`(codeium--nested-alist-set ,getter ,field ,v))
								 ,v))))))))


(defun codeium-compute-configs (api state vals-alist)
	(let (ans)
		(mapc
			(lambda (field)
				(setf (alist-get field ans) (codeium-get-config field api state (alist-get field vals-alist))))
			(codeium-get-config 'codeium-api-fields api state))
		ans))

(defun codeium-diagnose (&optional state)
	(interactive)
	(setq state (or state codeium-state))
	(with-output-to-temp-buffer "*codeium-diagnose*"
		(mapcar
			(lambda (api)
				(when (codeium-get-config 'codeium-api-enabled api codeium-state)
					(with-current-buffer standard-output
						(insert (propertize (symbol-name api) 'face '(:weight ultra-bold))))
					(terpri)
					(princ (url-recreate-url (codeium-get-config 'codeium-url api codeium-state)))
					(terpri)
					(mapcar
						(lambda (item)
							;; help-insert-xref-button
							(with-current-buffer standard-output
								(help-insert-xref-button (symbol-name (car item)) 'help-variable-def (car item))
								(insert (propertize "\t" 'display '(space :align-to 40))))
							(string-fill " " 5)
							(let*
								(
									(print-escape-newlines t) (print-length 100)
									(obj (cdr item))
									(obj (if (stringp obj)
											 (substring-no-properties obj 0 (length obj)) obj)))
								(cl-prin1 obj))
							(princ "\n"))
						(codeium-compute-configs api codeium-state nil))
					(princ "\n")))
			codeium-apis)
		(with-current-buffer standard-output
			(setq help-xref-stack-item (list #'codeium-diagnose codeium-state)))))


(defun codeium-make-body-for-api (api state vals-alist)
	(let (body tmp)
		(mapc
			(lambda (field)
				(setq tmp (codeium-get-config field api state (alist-get field vals-alist)))
				(when tmp
					(setf (codeium-nested-alist-get body field) tmp)))
			(codeium-get-config 'codeium-api-fields api state))
		body))

(defun codeium-get-or-make-process-buffer (state)
	(let ((buf (codeium-state-buf state)))
		(unless (and buf (buffer-live-p buf))
			(setq buf (generate-new-buffer "*codeium-log*"))
			(with-current-buffer buf
				(special-mode))
			(setf (codeium-state-buf state) buf))
		buf))

(defun codeium-get-unused-port-synchronously ()
	(let ((proc))
		(setq proc
			(make-network-process
				:name "get-port-temp"
				:service t
				:server t))
		(prog1
			(nth 1 (process-contact proc))
			(delete-process proc))))
(defun codeium-get-or-make-fixed-port (state)
	(let ((fixed-port (codeium-state-fixed-port state)))
		(unless fixed-port
			(setq fixed-port (codeium-get-unused-port-synchronously))
			(setf (codeium-state-fixed-port state) fixed-port))
		fixed-port))

(defun codeium-get-or-make-process (state)
	(let ((proc (codeium-state-proc state)) buf fixed-port)
		(unless (and proc (process-live-p proc))
			(setq buf (codeium-get-or-make-process-buffer state))
			(setq fixed-port (codeium-state-fixed-port state))
			(setq proc
				(make-process
					:name "codeium"
					:connection-type 'pipe
					:buffer buf
					:coding 'no-conversion
					:command `(,(codeium-get-config 'codeium-executable-loc nil state)
								  "--api_server_host" "server.codeium.com"
								  "--api_server_port" "443" 
								  ,@(when fixed-port `("--server_port" ,(number-to-string fixed-port)))
								  )
					:noquery t))
			(setf (codeium-state-proc state) proc))
		proc))

;; https://nullprogram.com/blog/2010/05/11/
;; ID: 90aebf38-b33a-314b-1198-c9bffea2f2a2
(defun codeium-uuid-create ()
	"Return a newly generated UUID. This uses a simple hashing of variable data."
	(let ((s (md5 (format "%s%s%s%s%s%s%s%s%s%s"
					  (user-uid)
					  (emacs-pid)
					  (system-name)
					  (user-full-name)
					  user-mail-address
					  (current-time)
					  (emacs-uptime)
					  (garbage-collect)
					  (random)
					  (recent-keys)))))
		(format "%s-%s-3%s-%s-%s"
			(substring s 0 8)
			(substring s 8 12)
			(substring s 13 16)
			(substring s 16 20)
			(substring s 20 32))))

(defvar codeium-last-auth-url nil)

(defun codeium-make-auth-url (state &optional uuid)
	(let*
		(
			(uuid (or uuid (codeium-uuid-create)))
			(query-params
				(url-build-query-string
					`(
						 ("response_type" "token")
						 ("state" ,uuid)
						 ("scope" "openid profile email")
						 ;; ("redirect_uri" "vim-show-auth-token")
						 ("redirect_uri" ,(url-recreate-url (codeium-get-config 'codeium-url 'auth-redirect state)))
						 ("redirect_parameters_type" "query"))))
			(url
				(url-recreate-url
					(url-parse-make-urlobj "https" nil nil "www.codeium.com" nil (concat "/profile?" query-params) nil nil t))))
		(setq codeium-last-auth-url url)))
(defun codeium-kill-last-auth-url ()
	(interactive)
	(when codeium-last-auth-url
		(message "%s sent to kill-ring" codeium-last-auth-url)
		(kill-new codeium-last-auth-url)))



(defun codeium-request-callback (status callback request-time log-marker)
	(when-let
		(
			(_ (markerp log-marker))
			(log-buf (marker-buffer log-marker))
			(status (or (if url-http-response-status url-http-response-status status) "no status available")))
		(with-current-buffer log-buf
			(save-excursion
				(let ((inhibit-read-only t) (print-escape-newlines t))
					(goto-char log-marker)
					(delete-char (- (1+ (length codeium-log-waiting-text))))
					(insert
						(format " status: %s %.2f secs"
							(prin1-to-string status)
							(float-time (time-subtract (current-time) request-time))))
					(set-marker log-marker (point))))))
	(funcall callback
		(if url-http-end-of-headers
			(let (parsed)
				(goto-char url-http-end-of-headers)
				(setq parsed (json-parse-buffer :object-type 'alist))
				;; (switch-to-buffer (current-buffer))
				(kill-buffer)
				(when-let
					(
						(_ (markerp log-marker))
						(log-buf (marker-buffer log-marker))
						(message
							(if (listp parsed)
								(or
									(alist-get 'state parsed)
									(alist-get 'message parsed)
									parsed)
								parsed))
						)
					(with-current-buffer log-buf
						(save-excursion
							(let ((inhibit-read-only t) (print-escape-newlines t))
								(goto-char log-marker)
								(insert
									(concat " " (prin1-to-string message)))))))
				parsed)
			'error)))

(defun codeium-request-with-body (state api body callback)
	(if (codeium-state-port state)
		(let*
			(
				(url (codeium-get-config 'codeium-url api state))
				(url-request-method "POST")
				(url-request-extra-headers `(("Content-Type" . "application/json")))
				(url-request-data (encode-coding-string (json-serialize body) 'utf-8))
				log-marker)
			(with-current-buffer (codeium-get-or-make-process-buffer state)
				(let ((inhibit-read-only t))
					(save-excursion
						(goto-char (point-max))
						(beginning-of-line)
						(insert-before-markers
							(format "[%s %s]\n" (url-recreate-url url) codeium-log-waiting-text))
						(setq log-marker (set-marker (make-marker) (- (point) 2)))
						)))
			(let ((url-buf (url-retrieve url 'codeium-request-callback (list callback (current-time) log-marker) 'silent 'inhibit-cookies)))
				(set-process-query-on-exit-flag (get-buffer-process url-buf) nil)))
		(codeium-on-port-ready state (lambda () (codeium-request-with-body state api body callback)))))

;; returns the body as returned by codeium-make-body-for-api, or nil if not codeium-api-enabled
(defun codeium-request (state api vals-alist callback)
	(when (codeium-get-config 'codeium-api-enabled api state)
		(setq body (codeium-make-body-for-api api state vals-alist))
		(codeium-request-with-body state api body callback)
		body))

(defun codeium-background-process-next (state)
	;; cancel-fn stores the function to cancel this function
	;; so we safely removes it
	(setf (codeium-state-background-process-cancel-fn state) nil)
	(codeium-background-process-start state))
(defun codeium-background-process-request (state api vals-alist callback)
	;; when the request is completed, we check if there has been any call to cancel earlier
	(let ((tracker (make-symbol "cancel-distinct-tracker")))
		(fset tracker #'ignore)
		(setf (codeium-state-background-process-cancel-fn state) tracker)
		(codeium-request state api vals-alist
			(lambda (res)
				(when (eq (codeium-state-background-process-cancel-fn state) tracker)
					(funcall callback res))))))
(defun codeium-background-process-start (state)
	;; entrypoint
	;; since user calls start, cancel previous stuff
	(when (codeium-state-background-process-cancel-fn state)
		(funcall (codeium-state-background-process-cancel-fn state))
		(setf (codeium-state-background-process-cancel-fn state) nil))
	(cond
		((input-pending-p)
			(let ((timer (run-with-idle-timer 0.05 nil #'codeium-background-process-next state)))
				(setf (codeium-state-background-process-cancel-fn state) (lambda () (cancel-timer timer)))))
		((or (not (codeium-state-proc state))
			 (not (process-live-p (codeium-state-proc state))))
			(setf (codeium-state-port state) nil)
			(codeium-get-or-make-fixed-port state) ;; TODO: replace wiht polling
			(codeium-get-or-make-process state)
			(codeium-background-process-start state))
		((not (codeium-state-port state))
			(if (codeium-state-fixed-port state)
				(let
					((timer
						 (run-with-timer 0.5 nil
							 (lambda ()
								 (setf (codeium-state-port state) (codeium-state-fixed-port state))
								 ;; save, incase the callbacks themselvesw need to modify the list
								 (while (codeium-state-port-ready-callback-list state)
									 (let ((callbacks (codeium-state-port-ready-callback-list state)))
										 (setf (codeium-state-port-ready-callback-list state) nil)
										 (mapc #'funcall callbacks)))
								 (codeium-background-process-next state)))))
					(setf (codeium-state-background-process-cancel-fn state) (lambda () (cancel-timer timer))))
				(error "abcd")))

		((and
			 (not (codeium-state-last-auth-token state))
			 (not (codeium-state-last-api-key state))
			 (not (codeium-get-config 'codeium/metadata/api_key 'GetCompletions state)))
			(let ((authurl (codeium-make-auth-url state)))
				(when (y-or-n-p (format "no codeium api-key found; visit %s to log in?" authurl))
					(browse-url authurl))
				(message "you can also use M-x codeium-kill-last-auth-url to copy the codeium login url"))
			(codeium-background-process-request state 'GetAuthToken nil
				(lambda (res)
					(if-let ((_ (listp res)) (token (alist-get 'authToken res)))
						(setf (codeium-state-last-auth-token state) token)
						(error "cannot get auth_token from res"))
					(codeium-background-process-next state))))

		((and
			 (not (codeium-state-last-api-key state))
			 (not (codeium-get-config 'codeium/metadata/api_key 'GetCompletions state)))
			(codeium-background-process-request state 'RegisterUser nil
				(lambda (res)
					(if-let ((_ (listp res)) (key (alist-get 'api_key res)))
						(progn
							(when (y-or-n-p "save codeium/metadata/api_key using customize?")
								(customize-save-variable 'codeium/metadata/api_key key))
							(setf (codeium-state-last-api-key state) key))
						(error "cannot get api_key from res"))
					(codeium-background-process-next state))))

		(t
			(codeium-background-process-request state 'Heartbeat nil
				(lambda (res)
					(let ((timer (run-with-timer 5 nil #'codeium-background-process-next state)))
						(setf (codeium-state-background-process-cancel-fn state) (lambda () (cancel-timer timer)))))))))

(defun codeium-reset-state (state)
	(when (codeium-state-background-process-cancel-fn state)
		(funcall (codeium-state-background-process-cancel-fn state))
		(setf (codeium-state-background-process-cancel-fn state) nil))
	(when-let ((proc (codeium-state-proc state)))
		(delete-process proc)
		(setf (codeium-state-proc state) proc))
	(setf (codeium-state-port state) nil)
	(setf (codeium-state-fixed-port state) nil)
	(setf (codeium-state-port-ready-callback-list state) nil)
	(setf (codeium-state-last-api-key state) nil)
	(setf (codeium-state-last-auth-token state) nil))


(defun codeium-on-port-ready (state callback)
	(unless (codeium-state-background-process-cancel-fn state)
		(codeium-background-process-start state))
	(if (codeium-state-port state)
		(funcall callback)
		(push callback (codeium-state-port-ready-callback-list state))))

;; returns (requestid . body_sent)
(defun codeium-request-getcompletions (state)
	(let ((requestid (cl-incf (codeium-state-last-request-id state))))
		(puthash requestid t (codeium-state-pending-table state))
		(cons requestid
			(codeium-request state 'GetCompletions nil
				(lambda (res)
					(when (gethash requestid (codeium-state-pending-table state))
						(remhash requestid (codeium-state-pending-table state))
						(puthash requestid res (codeium-state-results-table state))))))))

(defun codeium-request-cancelrequest (state requestid)
	(codeium-request state 'CancelRequest
		`((codeium/request_id . ,requestid))
		#'ignore))

;; returns (reqbody . res) or nil
(defun codeium-request-getcompletions-no-block (state)
	(unless (input-pending-p)
		(let*
			(
				(tmp (codeium-request-getcompletions state))
				(requestid (car tmp))
				(reqbody (cdr tmp))
				(rst 'noexist))
			(while (and (eq rst 'noexist) (not (input-pending-p)))
				(sit-for 0.01)
				(setq rst (gethash requestid (codeium-state-results-table state) 'noexist)))
			(if (eq rst 'noexist)
				(codeium-request-cancelrequest state
					(codeium-nested-alist-get reqbody 'codeium/metadata/request_id))
				(remhash requestid (codeium-state-results-table state)))
			(if (or (eq rst 'error) (eq rst 'noexist)) nil (cons reqbody rst)))))

(defun codeium-utf8-byte-length (str)
	(length (encode-coding-string str 'utf-8)))
(defun codeium-make-utf8-offset-table (str offsets)
	(let*
		(
			(str-cur 0)
			(str-len (length str))
			(offset-cur 0)
			(offset-max (apply #'max 0 offsets))
			(table (make-hash-table :test 'eql :weakness nil :size (* 2 (length offsets)))))
		(mapc
			(lambda (offset)
				(puthash offset nil table))
			offsets)
		(while (and (< str-cur str-len) (<= offset-cur offset-max))
			(dotimes (i (codeium-utf8-byte-length (substring-no-properties str str-cur (1+ str-cur))))
				(unless (eq (gethash offset-cur table 'noexist) 'noexist)
					(puthash offset-cur str-cur table))
				(cl-incf offset-cur))
			(cl-incf str-cur))
		(while (<= offset-cur offset-max)
			(puthash offset-cur str-len table)
			(cl-incf offset-cur))
		table))
(defmacro codeium-gv-map-table (gv table)
	`(setf ,gv (gethash (codeium-string-to-number-safe ,gv) ,table)))
(defmacro codeium-mapcar-mutate (func seq-gv)
	`(setf ,seq-gv (mapcar ,func ,seq-gv)))

(defun codeium-make-completion-string (completion-item document beg end)
	(let ((cur beg))
		(mapconcat
			(lambda (part)
				(when-let*
					(
						;; should be int since its been processed by codeium-parse-getcompletions-res-process-offsets
						(offset (alist-get 'offset part))
						(type (alist-get 'type part))
						(text (alist-get 'text part))
						(_ (or (string= type "COMPLETION_PART_TYPE_INLINE") (string= type "COMPLETION_PART_TYPE_BLOCK")))
						)
					(prog1
						(concat
							(substring document cur (min offset (length document)))
							;; (substring document (min cur offset (length document)) (min offset (length document)))
							(when (string= type "COMPLETION_PART_TYPE_BLOCK") "\n")
							text)
						(setq cur offset))))
			(append (alist-get 'completionParts completion-item) `(((offset . ,end))))
			"")))

(defun codeium-string-to-number-safe (str)
	(if (stringp str) (string-to-number str) str))
(defun codeium-parse-getcompletions-res-process-offsets (document cursor res)
	(let*
		(
			(items (alist-get 'completionItems res))
			(offsets-full-list
				(mapcar #'codeium-string-to-number-safe
					(remove nil
						(mapcan
							(lambda (item)
								(append
									(list
										(alist-get 'startOffset (alist-get 'range item))
										(alist-get 'endOffset (alist-get 'range item)))
									(mapcar
										(lambda (part) (alist-get 'offset part))
										(alist-get 'completionParts item))))
							items))))
			(offsets-table (codeium-make-utf8-offset-table document (push cursor offsets-full-list)))
			(_
				(codeium-mapcar-mutate
					(lambda (item)
						(codeium-gv-map-table (alist-get 'startOffset (alist-get 'range item)) offsets-table)
						(codeium-gv-map-table (alist-get 'endOffset (alist-get 'range item)) offsets-table)
						(codeium-mapcar-mutate
							(lambda (part)
								(codeium-gv-map-table (alist-get 'offset part) offsets-table)
								part)
							(alist-get 'completionParts item))
						item)
					items)))
		offsets-table))

;; WARNING: this mutates res
(defun codeium-parse-getcompletions-res (req res)
	;; (mapcar 'car res)
	;; (state completionItems requestInfo)
	;; (alist-get 'state res)
	;; (alist-get 'requestInfo res)

	;; (setq items (alist-get 'completionItems res))
	;; (setq item (elt items 0))
	;; (mapcar 'car item)
	;; (completion range source completionParts)
	;; (alist-get 'completion item)
	;; (alist-get 'range item)
	;; (alist-get 'source item)
	;; (alist-get 'completionParts item)
	;; (alist-get 'endOffset (alist-get 'range item))

	;; (print (alist-get 'state res))
	(when (alist-get 'completionItems res)
		(let*
			(
				(document (codeium-nested-alist-get req 'codeium/document/text))
				(cursor (codeium-nested-alist-get req 'codeium/document/cursor_offset))
				(items (alist-get 'completionItems res))
				(offset-hashtable (codeium-parse-getcompletions-res-process-offsets document cursor res))
				(cursor (gethash cursor offset-hashtable))
				offset-list
				(_
					(maphash (lambda (_ offset) (if offset (push offset offset-list))) offset-hashtable))
				(range-min (apply #'min cursor offset-list))
				(range-max (apply #'max cursor offset-list))
				(strings-list
					(mapcar
						(lambda (item) (codeium-make-completion-string item document range-min range-max))
						items)))
			;; (print (alist-get 'completionParts (elt items 0)))
			;; (print strings-list)
			;; (print (alist-get 'completion (elt items 0)))
			;; ;; (print (alist-get 'range (elt items 0)))
			;; ;; (print (alist-get 'source (elt items 0)))
			;; (print (list (- range-min cursor) (- range-max cursor) (nth 0 strings-list)))
			;; (print (list range-min cursor range-max))
			(list (- range-min cursor) (- range-max cursor) strings-list))))

;;;###autoload
(defun codeium-init (&optional state)
	(interactive)
	(setq state (or state codeium-state))
	(codeium-background-process-start state))

(defun codeium-reset (&optional state)
	(interactive)
	(setq state (or state codeium-state))
	(codeium-reset-state codeium-state))

;;;###autoload
(defun codeium-completion-at-point (&optional state)
	(setq state (or state codeium-state))
	;; (condition-case err
	(when-let*
		(
			(buffer-prev-str (buffer-string))
			(prev-point-offset (- (point) (point-min)))
			(tmp (codeium-request-getcompletions-no-block state))
			(req (car tmp))
			(res (cdr tmp))
			(rst (codeium-parse-getcompletions-res req res)))
		(cl-destructuring-bind (dmin dmax table) rst
			(when-let*
				(
					(rmin (+ dmin (point)))
					(rmax (+ dmax (point)))
					(pmin (+ dmin prev-point-offset))
					(pmax (+ dmax prev-point-offset))
					(_ (<= (point-min) rmin))
					(_ (<= rmax (point-max)))
					(_ (<= 0 pmin))
					(_ (<= pmax (length buffer-prev-str)))
					(_ (string=
						   (buffer-substring-no-properties rmin rmax)
						   (substring-no-properties buffer-prev-str pmin pmax))))
				(list rmin rmax table))))
	;; (error
	;; 	(message "an error occured in codeium-completion-at-point: %s" (error-message-string err))
	;; 	nil)
	;; )
	)

(provide 'codeium)
;;; codeium.el ends here

