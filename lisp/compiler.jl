#| compiler.jl -- compiler for Lisp files/forms

   $Id$

   Copyright (C) 1993, 1994, 2000 John Harper <john@dcs.warwick.ac.uk>

   This file is part of librep.

   librep is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   librep is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with librep; see the file COPYING.  If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.
|#

(define-structure compiler (export compile-file
				   compile-directory
				   compile-lisp-lib
				   compile-lib-batch
				   compile-batch
				   compile-compiler
				   compile-function
				   compile-form
				   compile-module)
  (open rep
	compiler-utils
	compiler-basic
	compiler-modules
	compiler-asm
	compiler-lap
	compiler-opt
	compiler-const
	compiler-bindings
	compiler-rep
	bytecodes)

  (define compiler-sources '(compiler
			     compiler-asm
			     compiler-basic
			     compiler-bindings
			     compiler-const
			     compiler-inline
			     compiler-lap
			     compiler-modules
			     compiler-opt
			     compiler-rep
			     compiler-src
			     compiler-utils
			     sort))

  ;; regexp matching library files not to compile
  (define lib-exclude-re "\\bautoload\\.jl$")

  ;; map languages to compiler modules
  (put 'rep 'compiler-module 'compiler-rep)
  (put 'scheme 'compiler-module 'compiler-scheme)

;;; Special variables

  (defvar *compiler-write-docs* nil
    "When t all doc-strings are appended to the doc file and replaced with
their position in that file.")

  (defvar *compiler-no-low-level-optimisations* nil)

  (defvar *compiler-debug* nil)



#| Notes:

Modules
=======

The compiler groks the rep module language, notably it will correctly
resolve (and perhaps inline) references to features of the rep
language, but only if the module header had `(open rep)' and the
feature hasn't been shadowed by a second module.

The compiler has also been written to enable other language dialects to
be compiled, for example `(open scheme)' could mark code as being
scheme. Several properties are set on the name of the module to handle
this:

	compiler-handler-property
	compiler-transform-property
	compiler-foldablep
	compiler-pass-1
	compiler-pass-2

see the compiler-rep module for example usage.

Instruction Encoding
====================

Instructions which get an argument (with opcodes of zero up to
`op-last-with-args') encode the type of argument in the low 3 bits of
their opcode (this is why these instructions take up 8 opcodes). A
value of 0 to 5 (inclusive) is the literal argument, value of 6 means
the next byte holds the argument, or a value of 7 says that the next
two bytes are used to encode the argument (in big- endian form, i.e.
first extra byte has the high 8 bits)

All instructions greater than the `op-last-before-jmps' are branches,
currently only absolute destinations are supported, all branch
instructions encode their destination in the following two bytes (also
in big-endian form).

Any opcode between `op-last-with-args' and `op-last-before-jmps' is a
straightforward single-byte instruction.

The machine simulated by lispmach.c is a simple stack-machine, each
call to the byte-code interpreter gets its own stack; the size of stack
needed is calculated by the compiler.

If you hadn't already noticed I based this on the Emacs version 18
byte-compiler.

Constants
=========

`defconst' forms have to be used with some care. The compiler assumes
that the value of the constant is always the same, whenever it is
evaluated. It may even be evaluated more than once.

In general, any symbols declared as constants (by defconst) have their
values set in stone. These values are hard-coded into the compiled
byte-code.

Also, the value of a constant-symbol is *not* likely to be eq to
itself!

Use constants as you would use macros in C, i.e. to define values which
have to be the same throughout a module. For example, this compiler
uses defconst forms to declare the instruction opcodes.

If you have doubts about whether or not to use constants -- don't; it
may lead to subtle bugs.

Inline Functions
================

The defsubst macro allows functions to be defined which will be open-
coded into any callers at compile-time. Of course, this can have a
similar effect to using a macro, with some differences:

	* Macros can be more efficient, since the formal parameters
	  are only bound at compile time. But, this means that the
	  arguments may be evaluated more than once, unlike a defsubst
	  where applied forms will only ever be evaluated once, when
	  they are bound to a formal parameter

	* Macros are more complex to write; though the backquote mechanism
	  can help a lot with this

	* defsubst's are more efficient in uncompiled code, but this
	  shouldn't really be a consideration, unless code is being
	  generated on the fly

Warnings
========

Currently warnings are generated for the following situations:

	* Functions or special variables are multiply defined
	* Undefined variables are referenced or set ("undefined" means
	  not defined by defvar, not currently (lexically) bound, and
	  not boundp at compile-time)
	* Undefined functions are referenced, that is, not defun'd and
	  not fboundp at compile-time
	* Functions are called with an incorrect number of arguments,
	  either too few required parameters, or too many supplied
	  to a function without a &rest keyword
	* Unreachable code in conditional statements
	* Possibly some other things...

TODO
====

Obviously, more optimisation of output code. This isdone in two stages,
(1) source code transformations, (2) optimisation of intermediate form
(basically bytecode, but as a list of operations and symbolic labels,
i.e. the basic blocks)

Both (1) and (2) are already being done, but there's probably scope for
being more aggressive, especially at the source code (parse tree)
level.

Optimisation would be a lot more profitable if variables were lexically
scoped, perhaps I should switch to lexical scoping. It shouldn't break
anything much, since the compiler will give warnings if any funky
dynamic-scope tricks are used without the symbols being defvar'd (and
therefore declared special/dynamic)

The constant folding code is a bit simplistic. For example the form (+
1 2 3) would be folded to 6, but (+ 1 2 x) *isn't* folded to (+ 3 x) as
we would like. This is due to the view of folded functions as
``side-effect-free constant black boxes''.

|#

;; 8/11/99: lexical scoping has arrived.. and it works.. and the
;; performance hit is minimal

;; so I need to do all those funky lexical scope optimisation now..


;;; Top level entrypoints

(defun compile-file (file-name)
  "Compiles the file of jade-lisp code FILE-NAME into a new file called
`(concat FILE-NAME ?c)' (ie, `foo.jl' => `foo.jlc')."
  (interactive "fLisp file to compile:")
  (let
      ((temp-file (make-temp-name))
       src-file dst-file body header form)
    (let-fluids ((current-file file-name)
		 (spec-bindings nil)
		 (lex-bindings nil))
    (unwind-protect
	(progn
	  (message (concat "Compiling " file-name "...") t)
	  (when (setq src-file (open-file file-name 'read))
	    (unwind-protect
		(progn
		  ;; Read the file

		  ;; First check for `#! .. !#' at start of file
		  (if (and (= (read-char src-file) ?#)
			   (= (read-char src-file) ?!))
		      (let
			  ((out (make-string-output-stream))
			   tem)
			(write out "#!")
			(catch 'done
			  (while (setq tem (read-char src-file))
			    (write out tem)
			    (when (and (= tem ?!)
				       (setq tem (read-char src-file)))
			      (write out tem)
			      (when (= tem ?#)
				(throw 'done t)))))
			(setq header (get-output-stream-string out)))
		    (seek-file src-file 0 'start))

		  ;; Scan for top-level definitions in the file.
		  ;; Also eval require forms (for macro defs)
		  (condition-case nil
		      (while t
			(setq body (cons (read src-file) body)))
		    (end-of-stream)))
	      (close-file src-file))
	    (setq body (compile-module-body (nreverse body) nil t t))
	    (when (setq dst-file (open-file temp-file 'write))
	      (condition-case error-info
		  (unwind-protect
		      (progn
			;; write out the results
			(when header
			  (write dst-file header))
			(format dst-file
				";; Source file: %s\n(validate-byte-code %d %d)\n"
				file-name bytecode-major bytecode-minor)
			(mapc (lambda (form)
				(when form
				  (print form dst-file))) body)
			(write dst-file ?\n))
		    (close-file dst-file))
		(error
		 ;; Be sure to remove any partially written dst-file.
		 ;; Also, signal the error again so that the user sees it.
		 (delete-file temp-file)
		 ;; Hack to signal error without entering the debugger (again)
		 (throw 'error error-info)))
	      ;; Copy the file to its correct location, and copy
	      ;; permissions from source file
	      (let
		  ((real-name (concat file-name (if (string-match
						     "\\.jl$" file-name)
						    ?c ".jlc"))))
		(copy-file temp-file real-name)
		(set-file-modes real-name (file-modes file-name)))
	      t)))
      (when (file-exists-p temp-file)
	(delete-file temp-file))))))

(defun compile-directory (dir-name &optional force-p exclude-re)
  "Compiles all jade-lisp files in the directory DIRECTORY-NAME whose object
files are either older than their source file or don't exist. If FORCE-P
is non-nil every lisp file is recompiled.

EXCLUDE-RE may be a regexp matching files which shouldn't be compiled."
  (interactive "DDirectory of Lisp files to compile:\nP")
  (mapc (lambda (file)
	  (when (and (string-match "\\.jl$" file)
		     (or (null exclude-re)
			 (not (string-match exclude-re file))))
	    (let*
		((fullname (expand-file-name file dir-name))
		 (cfullname (concat fullname ?c)))
	      (when (or (not (file-exists-p cfullname))
			(file-newer-than-file-p fullname cfullname))
		(compile-file fullname)))))
	(directory-files dir-name))
  t)

(defun compile-lisp-lib (&optional directory force-p)
  "Recompile all out of date files in the lisp library directory. If FORCE-P
is non-nil it's as though all files were out of date.
This makes sure that all doc strings are written to their special file and
that files which shouldn't be compiled aren't."
  (interactive "\nP")
  (let
      ((*compiler-write-docs* t))
    (compile-directory (or directory lisp-lib-directory)
		       force-p lib-exclude-re)))

;; Call like `rep --batch -l compiler -f compile-lib-batch [--force] DIR'
(defun compile-lib-batch ()
  (let
      ((force (when (equal (car command-line-args) "--force")
		(setq command-line-args (cdr command-line-args))
		t))
       (dir (car command-line-args)))
    (setq command-line-args (cdr command-line-args))
    (compile-lisp-lib dir force)))

;; Call like `rep --batch -l compiler -f compile-batch [--write-docs] FILES...'
(defun compile-batch ()
  (when (get-command-line-option "--write-docs")
    (setq *compiler-write-docs* t))
  (while command-line-args
    (compile-file (car command-line-args))
    (setq command-line-args (cdr command-line-args))))

;; Used when bootstrapping from the Makefile, recompiles compiler.jl if
;; it's out of date
(defun compile-compiler ()
  (let
      ((*compiler-write-docs* t))
    (mapc (lambda (package)
	    (let
		((file (expand-file-name (concat (symbol-name package) ".jl")
					 lisp-lib-directory)))
	      (when (or (not (file-exists-p (concat file ?c)))
			(file-newer-than-file-p file (concat file ?c)))
		(compile-file file))))
	  compiler-sources)))

(defun compile-function (function)
  "Compiles the body of the function FUNCTION."
  (interactive "aFunction to compile:")
  (let-fluids ((defuns nil)
	       (defvars nil)
	       (defines nil)
	       (current-fun function)
	       (output-stream nil))
  (let
      ((body (closure-function function)))
    (unless (bytecodep body)
      (call-with-module-declared
       (closure-structure function)
       (lambda ()
	 (set-closure-function function (compile-lambda body function)))))
    function)))

(defun compile-form (form)
  "Compile the Lisp form FORM into a byte code form."

  (let-fluids ((constant-alist '())
	       (constant-index 0)
	       (current-stack 0)
	       (max-stack 0)
	       (current-b-stack 0)
	       (max-b-stack 0)
	       (intermediate-code '()))

    ;; Do the high-level compilation
    (compile-form-1 form t)
    (emit-insn (bytecode return))

    ;; Now we have a [reversed] list of intermediate code
    (fluid-set intermediate-code (nreverse (fluid intermediate-code)))

    ;; Unless disabled, run the peephole optimiser
    (unless *compiler-no-low-level-optimisations*
      (when *compiler-debug*
	(format standard-error "lap-0 code: %S\n\n" (fluid intermediate-code)))
      (fluid-set intermediate-code (peephole-optimizer
				    (fluid intermediate-code))))
    (when *compiler-debug*
      (format standard-error "lap-1 code: %S\n\n" (fluid intermediate-code)))

    ;; Then optimise the constant layout
    (unless *compiler-no-low-level-optimisations*
      (when *compiler-debug*
	(format standard-error
		"original-constants: %S\n\n" (fluid constant-alist)))
      (fluid-set intermediate-code (constant-optimizer
				    (fluid intermediate-code)))
      (when *compiler-debug*
	(format standard-error
		"final-constants: %S\n\n" (fluid constant-alist))))

    ;; Now transform the intermediate code to byte codes
    (when *compiler-debug*
      (format standard-error "lap-2 code: %S\n\n" (fluid intermediate-code)))
    (list 'run-byte-code
	  (assemble-bytecodes (fluid intermediate-code))
	  (make-constant-vector)
	  (+ (fluid max-stack) (ash (fluid max-b-stack) 16))))))
