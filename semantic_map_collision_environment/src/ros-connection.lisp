;;;
;;; Copyright (c) 2011, Lorenz Moesenlechner <moesenle@in.tum.de>
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
;;;     * Neither the name of the Intelligent Autonomous Systems Group/
;;;       Technische Universitaet Muenchen nor the names of its contributors 
;;;       may be used to endorse or promote products derived from this software 
;;;       without specific prior written permission.
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
;;;

(in-package :sem-map-coll-env)

(defvar *marker-publisher* nil)
(defvar *collision-object-publisher* nil)

(defvar *semantic-map-obj-cache* (make-hash-table :test 'equal))

(defun init-semantic-map-collision-environment ()
  (setf *marker-publisher*
        (roslisp:advertise "~semantic_map_markers" "visualization_msgs/Marker"))
  (setf *collision-object-publisher*
        (roslisp:advertise "/collision_object" "arm_navigation_msgs/CollisionObject")))

(register-ros-init-function init-semantic-map-collision-environment)

(defun init-semantic-map-obj-cache ()
  (lazy-dolist (obj (query-sem-map))
    (with-slots (name) obj
      (if (gethash name *semantic-map-obj-cache*)
          (push obj (gethash name *semantic-map-obj-cache*))
          (setf (gethash name *semantic-map-obj-cache*) (list obj))))))

(defun invalidate-semantic-map-obj-cache ()
  (setf *semantic-map-obj-cache* (make-hash-table :test 'equal)))

(defun publish-semantic-map-collision-objects ()
  (unless (> (hash-table-count *semantic-map-obj-cache*) 0)
    (init-semantic-map-obj-cache))
  (loop for objs being the hash-values of *semantic-map-obj-cache* do
    (dolist (obj objs)
      (roslisp:publish *collision-object-publisher* (collision-object->msg obj)))))

(defun remove-semantic-map-collision-objects ()
  (unless (> (hash-table-count *semantic-map-obj-cache*) 0)
    (init-semantic-map-obj-cache))
  (loop for objs being the hash-values of *semantic-map-obj-cache* do
    (dolist (obj objs)
      (roslisp:publish
       *collision-object-publisher*
       (roslisp:make-msg
        "arm_navigation_msgs/CollisionObject"
        (stamp header) (roslisp:ros-time)
        (frame_id header) "odom_combined"
        id (make-collision-obj-name obj)
        (operation operation) 1)))))

(defun update-sem-map-obj-pose (obj-descr new-pose)
  "Changes the pose of a semantic map object and publishes the
  corresponding message on /collision_object. `obj-descr' is either an
  instance of SEM-MAP-OBJ, or a string indicating the name of the
  object to be updated. `new-pose' specifies the new pose. If more
  than one objects match `obj-descr' an error is thrown."
  (let ((objs (etypecase obj-descr
                (sem-map-obj (list obj-descr))
                (string (gethash obj-descr *semantic-map-obj-cache*)))))
    (assert objs () "Invalid object `~a'" obj-descr)
    (assert (= (length objs) 1) ()
            "More than one matching SEM-MAP-OBJ found")
    (with-slots (pose) (car objs)
      (setf pose new-pose))
    (roslisp:publish *collision-object-publisher* (collision-object->msg (car objs)))))

(defun publish-semantic-map-markers ()
  (unless (> (hash-table-count *semantic-map-obj-cache*) 0)
    (init-semantic-map-obj-cache))
  (loop for objs being the hash-values of *semantic-map-obj-cache* do
    (dolist (obj objs)
      (roslisp:publish *marker-publisher* (collision-object->marker obj)))))

(defun collision-object->marker (obj &optional (frame-id "/map"))
  (declare (type sem-map-obj obj))
  (with-slots (name index pose dimensions) obj
    (roslisp:make-msg
     "visualization_msgs/Marker"
     (frame_id header) frame-id
     ns name
     id index
     type 1
     action 0
     pose (tf:pose->msg pose)
     (x scale) (x dimensions)
     (y scale) (y dimensions)
     (z scale) (z dimensions)
     (r color) 0.0
     (g color) 0.0
     (b color) 1.0
     (a color) 0.5)))

(defun collision-object->msg (obj &optional (frame-id "/map"))
  (declare (type sem-map-obj obj))
  (with-slots (pose dimensions) obj
    (roslisp:make-msg
     "arm_navigation_msgs/CollisionObject"
     (frame_id header) frame-id
     (stamp header) (roslisp:ros-time)
     id (make-collision-obj-name obj)
     (operation operation) 0
     shapes (vector (roslisp:make-msg
                     "arm_navigation_msgs/Shape"
                     type 1
                     dimensions (vector
                                 (x dimensions)
                                 (y dimensions)
                                 (z dimensions))))
     poses (vector (tf:pose->msg pose)))))

(defun make-collision-obj-name (obj)
  (with-slots (name index) obj
    (format nil "~a-~a" name index)))
