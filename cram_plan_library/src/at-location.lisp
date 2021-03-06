;;; Copyright (c) 2010, Lorenz Moesenlechner <moesenle@in.tum.de>
;;; All rights reserved.
;;; 
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;; 
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;     * Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;     * Neither the name of Willow Garage, Inc. nor the names of its
;;;       contributors may be used to endorse or promote products derived from
;;;       this software without specific prior written permission.
;;; 
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.

(in-package :plan-lib)

(defvar *at-location-lock* (sb-thread:make-mutex :name "AT-LOCATION-LOCK")
  "Mutex that is used to synchronize on parallel AT-LOCATION forms. To
prevent oscillations, we need to wait until one AT-LOCATION form
terminates before executing the body of the second one.")

(defvar *navigating-lock* (sb-thread:make-mutex :name "NAVIGATING-LOCK")
  "Mutex to synchronize calls to NAVIGATE and prevent race conditions
  where at-location starts executing at a location and another
  navigate just moves away.")

(defconstant +at-location-retry-count+ 10
  "Number of retries if at-location detects that the location is lost,
  evaporates the body and triggers navigation again.")

(cram-projection:define-special-projection-variable *at-location-lock*
    (sb-thread:make-mutex :name "AT-LOCATION-PROJECTION-LOCK"))

(cram-projection:define-special-projection-variable *navigating-lock*
    (sb-thread:make-mutex :name "NAVIGATING-PROJECTION-LOCK"))

(defun location-designator-reached (current-location location-designator)
  "Returns a boolean fluent that indicates if `current-location' is a
valid solution for `location-designator'"
  (validate-location-designator-solution location-designator current-location))

(defmacro with-equate-fluent ((designator fluent-name) &body body)
  "Executes `body' with `fluent-name' bound to a lexical variable. The
fluent is pulsed whenever `designator' is equated to another
designator."
  (alexandria:with-gensyms (callback)
    `(let ((,fluent-name (make-fluent :value nil :name ',fluent-name)))
       (flet ((,callback (other)
                (declare (ignore other))
                (pulse ,fluent-name)))
         (with-equate-callback (,designator #',callback)
           ,@body)))))

(defun %execute-at-location (loc-var function)
  (let ((terminated nil)
        (robot-location-changed-fluent (make-fluent :allow-tracing nil))
        (result-values nil)
        (pulse-thread nil)
        (at-location-task *current-task*))
    (flet ((set-current-location ()
             (unless (and pulse-thread
                          (sb-thread:thread-alive-p pulse-thread))
               (setf pulse-thread
                     (sb-thread:make-thread
                      (lambda ()
                        (tv-closure
                         nil at-location-task
                         (lambda  ()
                           (pulse robot-location-changed-fluent)))))))))
      (tf:with-transforms-changed-callback (*tf* #'set-current-location)
        (with-equate-fluent (loc-var designator-updated)
          (loop
            for navigation-done = (make-fluent :value nil)
            for location-lost-count from 0
            when (>= location-lost-count +at-location-retry-count+) do
              (fail 'simple-plan-failure
                    :format-control "Navigation lost ~a times. Aborting"
                    :format-arguments (list location-lost-count))
            until terminated do
              (pursue
                (cond ((sb-thread:with-mutex (*navigating-lock*)
                         (and (sb-thread:mutex-owner *at-location-lock*)
                              (location-designator-reached
                               (current-robot-location) loc-var)
                              (setf (value navigation-done) t)))
                       (sb-thread:with-mutex (*at-location-lock*)
                         (wait-for (make-fluent :value nil)))
                       nil)
                      (t
                       (sb-thread:with-mutex (*at-location-lock*)
                         (sb-thread:with-mutex (*navigating-lock*)
                           (navigate loc-var)
                           (setf (value navigation-done) t))
                         ;; Wait for ever, i.e. terminate (and
                         ;; release the mutex) only when the other
                         ;; branch of pursue terminates. This is
                         ;; necessary because we want to keep the
                         ;; log until AT-LOCATION terminates.
                         (wait-for (make-fluent :value nil)))))
                (seq
                  (wait-for navigation-done)
                  (assert (location-designator-reached
                           (current-robot-location) loc-var))
                  (pursue
                    ;; We are ignoring the designator-updated and
                    ;; location-changed fluents inside the body of the
                    ;; lambda function since it is only used to trigger
                    ;; the lambda function in case the designator or
                    ;; the robot's location changes. The data for
                    ;; actually checking if the robot is still at the
                    ;; correct location is computed inside the lambda
                    ;; function.
                    ;;
                    ;; Note(moesenle): The fl-funcall function might be
                    ;; executed even when none of the input fluents
                    ;; changed its values. The reason is that WAIT-FOR
                    ;; uses a condition variable to be notified on
                    ;; fluent changes and then call VALUE which causes
                    ;; re-calculation of the fluent's value.
                    (wait-for (fl-funcall (lambda (location-changed designator-updated)
                                            (declare (ignore location-changed
                                                             designator-updated))
                                            (not (location-designator-reached
                                                  (current-robot-location) loc-var)))
                                          (pulsed robot-location-changed-fluent)
                                          (pulsed designator-updated)))
                    (seq
                      (setf result-values (multiple-value-list (funcall function)))
                      (setf terminated t)))))
            finally (return (apply #'values result-values))))))))

(defmacro at-location (&whole sexp (location) &body body)
  `(flet ((at-location-body () ,@body))
     (let ((evaluated-location ,location))
       ;; We dereference the location before creating a new task to
       ;; make sure that in case the location cannot be resolved, the
       ;; error is thrown in the parent task. That way, if the user
       ;; handles it using WITH-FAILURE-HANDLING, Lisp won't enter the
       ;; debugger.
       (reference evaluated-location)
       (with-task-tree-node (:path-part `(goal-context (at-location (?loc)))
                             :name "AT-LOCATION"
                             :sexp ,sexp
                             :lambda-list (evaluated-location)
                             :parameters (list evaluated-location))
         (%execute-at-location evaluated-location #'at-location-body)))))
