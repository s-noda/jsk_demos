(load "package://drc_task_common/euslisp/robot-util.l")
(load "package://drc_task_common/euslisp/util.l")

(defun set-valve-environment
  (&key (valve-r 200)
        (valve-coords (make-coords :pos (float-vector 0 0 1200) :rpy (list 0 pi/2 0)))
        (generate-ri? t) (draw? t)
        (robot-name "HRP2JSKNTS"))
  ;; generate robot
  (generate-robot robot-name :generate-ri? generate-ri?)
  ;; place robot to origin
  (send *robot* :reset-manip-pose)
  (send *robot* :fix-leg-to-coords (make-coords))
  ;; attach handle to robot
  (send *robot* :put :larm-valve-coords
        (make-cascoords
         :coords (send (send (send *robot* :larm :end-coords) :copy-worldcoords) :translate (float-vector 25.0 5.0 0.0) :local)
         :parent (send (send *robot* :larm :end-coords) :parent)))
  (send *robot* :put :rarm-valve-coords
        (make-cascoords
         :coords (send (send (send *robot* :rarm :end-coords) :copy-worldcoords) :translate (float-vector 25.0 -5.0 0.0) :local)
         :parent (send (send *robot* :rarm :end-coords) :parent)))
  ;; generate valve
  (let* ((valve-sr (* 0.1 valve-r)))
    (setq *valve* (make-ring valve-r valve-sr :segments 16))
    (send *valve* :set-color (float-vector 1 1 0))
    )
  ;; atattch handle to valve
  (send *valve* :put :grasp-coords
        (make-cascoords
         :coords (make-coords :pos (float-vector valve-r 0 0) :rpy (list pi/2 -pi/2 0))
         :parent *valve*))
  ;; place valve to valve-coords
  (when valve-coords
    (send *valve* :newcoords valve-coords))
  (setq *valve-stand-coords* nil)
  ;; draw
  (setq *ground* (make-cube 1000 1000 1))
  (when (or draw? (boundp '*irtviewer*))
    (objects (list *robot* *valve* *ground*)))
  (when draw?
    (send *irtviewer* :draw-objects)
    (send *irtviewer* :change-background (float-vector 1 1 1))
    )
  )

(defun set-valve-environment-full
  (valve-r
   valve-coords ;; body relative
   &key
   (draw? nil)
   (use-ri? t))
  (let* (valve-worldcoords)
    ;; place robot and valve to initial coords
    (set-valve-environment :valve-r valve-r :valve-coords nil :draw? draw? :generate-ri? use-ri?)
    (cond (use-ri?
           (send *robot* :angle-vector (send *ri* :state :potentio-vector)))
          (t
           (send *robot* :angle-vector (get-potentio-vector-from-joint-states))))
    (send *robot* :fix-leg-to-coords (make-coords) '(:lleg :rleg))
    (send *valve* :newcoords (send (send (send *robot* :body_lk) :copy-worldcoords) :transform valve-coords :local))
    (when draw? (send *irtviewer* :draw-objects))
    ))

(defun reset-valve-angle
  ()
  (let* ((handle-height-min 1e10)
         valve-rot-min)
    (dotimes (i 360)
      (send *valve* :rotate (deg2rad 1) :z :local)
      (when (> handle-height-min (elt (send (send *valve* :get :grasp-coords) :worldpos) 2))
        (setq handle-height-min (elt (send (send *valve* :get :grasp-coords) :worldpos) 2))
        (setq valve-rot-min (send (send (send *valve* :worldcoords) :copy-worldcoords) :worldrot))
        )
      )
    (send *valve* :newcoords (make-coords :pos (send (send *valve* :worldcoords) :worldpos) :rot valve-rot-min))
    )
  )

(defun fullbody-inverse-kinematics-for-valve
  (tc mt ll &key (draw? nil))
  (send *robot*
        :fullbody-inverse-kinematics tc
        :move-target mt :link-list ll
        :additional-weight-list
        (list (list (send *robot* :rleg :toe-p :child-link) 0)
              (list (send *robot* :lleg :toe-p :child-link) 0))
        :root-link-virtual-joint-weight (float-vector 0.1 0.1 0.1 0.1 0.5 0.5)
        :target-centroid-pos (apply #'midpoint 0.5 (send *robot* :legs :end-coords :worldpos))
        :translation-axis (list t t t)
        :rotation-axis (list t t t)
        :max (float-vector  500  500  0  20  20  10) ;; for hrp2
        :min (float-vector  -500  -500  -200  -20  -20  -10) ;; for hrp2
        :stop 20
        :debug-view (if draw? :no-message nil)
        :warnp (if draw? t nil)
        ))

(defun generate-valve-motion
  (&key (draw? t))
  ;; reset valve angle
  (reset-valve-angle)
  ;; loop
  (let* ((devide-num 10)
         (reach-dist 100)
         (ik-results nil)
         (original-foot-midcoords (send (send *robot* :foot-midcoords) :copy-worldcoords)))
    ;; rotate valve
    (dotimes (i devide-num)
      (send *robot* :reset-manip-pose)
      (send *robot* :fix-leg-to-coords original-foot-midcoords)
      ;; solve ik to rotate valve
      (let* (ik-ret-in
             ik-ret-out
             tc)
        (when draw? (send (send *valve* :get :grasp-coords) :draw-on :flush t))
        ;; solve ik for valve handle
        (setq tc
              (list
               (send *valve* :get :grasp-coords)
               (send *robot* :rleg :end-coords :copy-worldcoords)
               (send *robot* :lleg :end-coords :copy-worldcoords)))
        (with-move-target-link-list
         (mt ll *robot* '(:rarm :rleg :lleg))
         (setf (elt mt 0) (send *robot* :get :rarm-valve-coords))
         (setq ik-ret-in (fullbody-inverse-kinematics-for-valve tc mt ll :draw? draw?))
         (when ik-ret-in
           (setq ik-ret-in (send *robot* :look-at-target (send *valve* :worldcoords)))))
        ;; solve ik for valve reaching point
        (setq tc
              (list
               (send (send (send *valve* :get :grasp-coords) :copy-worldcoords) :translate (float-vector (- reach-dist) (- reach-dist) 0) :local)
               (send *robot* :rleg :end-coords :copy-worldcoords)
               (send *robot* :lleg :end-coords :copy-worldcoords)))
        (when ik-ret-in
          (with-move-target-link-list
           (mt ll *robot* '(:rarm :rleg :lleg))
           (setf (elt mt 0) (send *robot* :get :rarm-valve-coords))
           (setq ik-ret-out (fullbody-inverse-kinematics-for-valve tc mt ll :draw? draw?))
           (when ik-ret-out
             (setq ik-ret-out (send *robot* :look-at-target (send *valve* :worldcoords))))))
        (push-back (list i (not (null (and ik-ret-in ik-ret-out))) ik-ret-in ik-ret-out) ik-results)
        ;; draw
        (when draw? (send *irtviewer* :draw-objects :flush t))
        )
      (setq *valve-ik-results* ik-results)
      ;; rotate valve
      (send *valve* :rotate (+ (deg2rad (/ 360.0 devide-num))) :z :local)
      )
    ))

(defun search-rotatable-range
  ()
  (let* ((ik-results-double (append *valve-ik-results* *valve-ik-results*))
         (test-point 0)
         (rotatable-point nil))
    (dotimes (i (/ (length ik-results-double) 2))
      (let (j)
        (setq test-point 0)
        (setq j (+ i 1))
        (when (car (cdr (nth i ik-results-double)))
          (incf test-point)
          (while (car (cdr (nth j ik-results-double)))
            (incf test-point)
            (incf j)))
        (push-back test-point rotatable-point)
        ))
    rotatable-point
    ))

(defun get-rotatable-angle
  ()
  (* 360 (/ (float (apply #'max (search-rotatable-range))) (length *valve-ik-results*))))

(defun get-valve-motion
  (&key (draw? nil))
  (generate-valve-motion :draw? draw?)
  (let* ((valve-rotatable-range (search-rotatable-range))
         (rotatable-point-max (apply #'max valve-rotatable-range))
         (rotatable-point-idx (position (apply #'max valve-rotatable-range) valve-rotatable-range))
         angle-vector-ret angle-vector-ret-release)
    (dotimes (i (length valve-rotatable-range))
      (when (= (elt valve-rotatable-range rotatable-point-idx) 0)
        (return-from nil nil))
      (push-back (elt (elt *valve-ik-results* rotatable-point-idx) 2) angle-vector-ret)
      (push-back (elt (elt *valve-ik-results* rotatable-point-idx) 3) angle-vector-ret-release)
      (setq rotatable-point-idx (mod (+ rotatable-point-idx 1) (length valve-rotatable-range)))
      )
    (setq *valve-motion* (append angle-vector-ret (reverse angle-vector-ret-release)))
    *valve-motion*
    ))

(defun get-valve-stand-coords ;; relative to valve
  ()
  (make-coords :pos (float-vector -500 120 0) :rpy (list (deg2rad 0) 0 0)) ;; dependent on arm
  )

(defun get-valve-motion-full
  (valve-r
   valve-coords
   &key (draw? nil) (use-ri? t))
  (let* ((rotatable-angle-thre 100))
    (set-valve-environment-full valve-r valve-coords :draw? draw? :use-ri? use-ri?)
    (get-valve-motion :draw? draw?)
    ;; when motion is not good, change stand position
    (unless (> (get-rotatable-angle) rotatable-angle-thre)
      (let* ((x-vec (send (send (send *valve* :worldcoords) :copy-worldcoords) :rotate-vector (float-vector 0 0 1)))
             (z-vec (float-vector 0 0 1))
             (y-vec (v* z-vec x-vec))
             (valve-coords-stand-rot (make-coords :pos (send (send *valve* :copy-worldcoords) :worldpos) :rot (transpose (matrix x-vec y-vec z-vec))))
             (stand-coords (send (send valve-coords-stand-rot :copy-worldcoords) :transform (get-valve-stand-coords) :local))
             (stand-pos (send stand-coords :worldpos))
             (stand-rpy (elt (send stand-coords :rpy-angle) 0))
             )
        (setq *valve-stand-coords* (make-coords :pos (float-vector (elt stand-pos 0) (elt stand-pos 1) 0) :rpy (list (elt stand-rpy 0) 0 0)))
        )
      (ros::ros-warn "change stand position to ~a for valve motion.~%" *valve-stand-coords*)
      (send *robot* :fix-leg-to-coords *valve-stand-coords*)
      (when draw? (send *irtviewer* :draw-objects))
      (get-valve-motion :draw? draw?))
    *valve-motion*))

(defun send-valve-motion
  (radius coords &key (real? t))
  (let* ((rotate-num 3)
         (valve-motion-av-list (get-valve-motion-full radius coords))
         (valve-motion-length (length valve-motion-av-list)))
    (when (not (= valve-motion-length 0))
      ;; reset-manip-pose
      (send *robot* :hand :arms :hook-pose) ;; hand hook-pose
      (when real? (hand-model2real))
      (send *robot* :reset-manip-pose)
      (unless (check-angle-vector-distance)
        (when real? (model2real :time 3000)))
      (when real? (send *ri* :start-impedance :arms :moment-gain (float-vector 0 0 0) :k-p 800 :d-p 400)) ;; start imp
      ;; walk
      (when *valve-stand-coords*
        (let* ((pos (scale 0.001 (send *valve-stand-coords* :worldpos)))
               (rpy (mapcar #'rad2deg (car (send *valve-stand-coords* :rpy-angle)))))
          (ros::ros-warn "go-pos to ~a ~a ~a for valve~%" (elt pos 0) (elt pos 1) (elt rpy 0))
          (when real? (send *ri* :go-pos (elt pos 0) (elt pos 1) (elt rpy 0)))
          ))
      ;; pre grasp
      (send *robot* :angle-vector (car (last valve-motion-av-list)))
      (when real? (model2real :time 5000))
      (dotimes (i rotate-num)
        ;; grasp
        (send *robot* :angle-vector (car valve-motion-av-list))
        (when real? (model2real :time 3000))
        (send *robot* :hand :arms :extension-pose) ;; hand extension-pose
        (when real? (hand-model2real))
        (send *robot* :hand :arms :grasp-pose) ;; hand grasp-pose
        (when real? (hand-model2real))
        ;; rotate
        (when real? (send-angle-vector-sequence-with-time (cdr (subseq valve-motion-av-list 0 (/ valve-motion-length 2))) :time 1500 :wait? t))
        ;; relese
        (send *robot* :hand :arms :hook-pose) ;; hand hook-pose
        (when real? (hand-model2real))
        (send *robot* :angle-vector (car (subseq valve-motion-av-list (/ valve-motion-length 2))))
        (when real? (model2real :time 3000))
        (cond ((= i (1- rotate-num))
               ;; last releasing
               (send *robot* :reset-manip-pose)
               (when real? (model2real :time 5000)))
              (t
               ;; reverse
               (when real? (send-angle-vector-sequence-with-time (cdr (subseq valve-motion-av-list (/ valve-motion-length 2))) :time 1500 :wait? t))
               ))
        )))
  )

(defun publish-valve-motion
  (&key radius coords (step-time 400) (update? t))
  (when update?
    (get-valve-motion-full radius coords :use-ri? nil))
  (ros::ros-info "valve-stand-coords: ~a~%" *valve-stand-coords*)
  (ros::ros-info "valve-ik-results: ~a~%" *valve-ik-results*)
  (when *valve-stand-coords*
    (move-robot-model *valve-stand-coords* "ground"))
  (publish-motion-joint-states *valve-motion* :step-time step-time)
  )

(defun test-valve-motion1
  ()
  (get-valve-motion-full 150 (make-coords :pos #f(400 0 250) :rpy (list 0 pi/2 0)) :draw? nil :use-ri? t)
  (when *valve-stand-coords*
    (send *robot* :fix-leg-to-coords *valve-stand-coords*))
  (play-motion-on-eus-viewer *valve-motion*)
  )

(defun test-valve-motion2
  ()
  (get-valve-motion-full 150 (make-coords :pos #f(1000 0 250) :rpy (list 0 pi/2 0)) :draw? nil :use-ri? t)
  (when *valve-stand-coords*
    (send *robot* :fix-leg-to-coords *valve-stand-coords*))
  (play-motion-on-eus-viewer *valve-motion*)
  )
