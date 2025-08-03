;; Multi-Site Coordination Contract
;; Synchronizes patient enrollment and data collection across multiple research locations

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-INVALID-INPUT (err u501))
(define-constant ERR-SITE-NOT-FOUND (err u502))
(define-constant ERR-TRIAL-NOT-FOUND (err u503))
(define-constant ERR-ENROLLMENT-FULL (err u504))
(define-constant ERR-SITE-INACTIVE (err u505))

;; Site Status
(define-constant SITE-STATUS-PENDING u1)
(define-constant SITE-STATUS-ACTIVE u2)
(define-constant SITE-STATUS-SUSPENDED u3)
(define-constant SITE-STATUS-CLOSED u4)

;; Data Variables
(define-data-var next-site-id uint u1)
(define-data-var next-enrollment-id uint u1)

;; Data Maps
(define-map research-sites
  { site-id: uint }
  {
    name: (string-ascii 100),
    location: (string-ascii 100),
    principal-investigator: principal,
    contact-info-hash: (buff 32),
    certification-hash: (buff 32),
    status: uint,
    activated-at: (optional uint),
    max-capacity: uint,
    current-enrollment: uint
  }
)

(define-map trial-site-assignments
  { trial-id: uint, site-id: uint }
  {
    assigned-at: uint,
    target-enrollment: uint,
    current-enrollment: uint,
    enrollment-rate: uint,
    is-active: bool,
    coordinator: principal
  }
)

(define-map patient-enrollments
  { enrollment-id: uint }
  {
    patient-id: uint,
    trial-id: uint,
    site-id: uint,
    enrollment-date: uint,
    enrolled-by: principal,
    randomization-code: (optional (string-ascii 50)),
    treatment-arm: (optional (string-ascii 50)),
    status: (string-ascii 20)
  }
)

(define-map site-communications
  { site-id: uint, message-id: uint }
  {
    sender-site: uint,
    message-hash: (buff 32),
    message-type: (string-ascii 50),
    timestamp: uint,
    priority: uint,
    requires-response: bool
  }
)

(define-map data-synchronization
  { trial-id: uint, sync-id: uint }
  {
    sync-date: uint,
    participating-sites: (list 10 uint),
    data-hash: (buff 32),
    sync-status: (string-ascii 20),
    initiated-by: principal
  }
)

(define-map authorized-coordinators
  { coordinator: principal }
  {
    is-authorized: bool,
    site-id: uint,
    permissions: uint
  }
)

;; Authorization Functions
(define-public (authorize-coordinator (coordinator principal) (site-id uint) (permissions uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-coordinators
      { coordinator: coordinator }
      { is-authorized: true, site-id: site-id, permissions: permissions }
    ))
  )
)

;; Site Management
(define-public (register-site (name (string-ascii 100)) (location (string-ascii 100)) (principal-investigator principal) (contact-info-hash (buff 32)) (certification-hash (buff 32)) (max-capacity uint))
  (let
    (
      (site-id (var-get next-site-id))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> max-capacity u0) ERR-INVALID-INPUT)

    (map-set research-sites
      { site-id: site-id }
      {
        name: name,
        location: location,
        principal-investigator: principal-investigator,
        contact-info-hash: contact-info-hash,
        certification-hash: certification-hash,
        status: SITE-STATUS-PENDING,
        activated-at: none,
        max-capacity: max-capacity,
        current-enrollment: u0
      }
    )
    (var-set next-site-id (+ site-id u1))
    (ok site-id)
  )
)

(define-public (activate-site (site-id uint))
  (let
    (
      (site (unwrap! (map-get? research-sites { site-id: site-id }) ERR-SITE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status site) SITE-STATUS-PENDING) ERR-INVALID-INPUT)

    (map-set research-sites
      { site-id: site-id }
      (merge site {
        status: SITE-STATUS-ACTIVE,
        activated-at: (some block-height)
      })
    )
    (ok true)
  )
)

;; Trial-Site Assignment
(define-public (assign-trial-to-site (trial-id uint) (site-id uint) (target-enrollment uint) (coordinator principal))
  (let
    (
      (site (unwrap! (map-get? research-sites { site-id: site-id }) ERR-SITE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status site) SITE-STATUS-ACTIVE) ERR-SITE-INACTIVE)
    (asserts! (> target-enrollment u0) ERR-INVALID-INPUT)

    (map-set trial-site-assignments
      { trial-id: trial-id, site-id: site-id }
      {
        assigned-at: block-height,
        target-enrollment: target-enrollment,
        current-enrollment: u0,
        enrollment-rate: u0,
        is-active: true,
        coordinator: coordinator
      }
    )
    (ok true)
  )
)

;; Patient Enrollment
(define-public (enroll-patient (patient-id uint) (trial-id uint) (site-id uint) (randomization-code (optional (string-ascii 50))) (treatment-arm (optional (string-ascii 50))))
  (let
    (
      (enrollment-id (var-get next-enrollment-id))
      (site (unwrap! (map-get? research-sites { site-id: site-id }) ERR-SITE-NOT-FOUND))
      (assignment (unwrap! (map-get? trial-site-assignments { trial-id: trial-id, site-id: site-id }) ERR-TRIAL-NOT-FOUND))
      (coordinator-auth (default-to { is-authorized: false, site-id: u0, permissions: u0 } (map-get? authorized-coordinators { coordinator: tx-sender })))
    )
    (asserts! (get is-authorized coordinator-auth) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get site-id coordinator-auth) site-id) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status site) SITE-STATUS-ACTIVE) ERR-SITE-INACTIVE)
    (asserts! (get is-active assignment) ERR-INVALID-INPUT)
    (asserts! (< (get current-enrollment assignment) (get target-enrollment assignment)) ERR-ENROLLMENT-FULL)
    (asserts! (< (get current-enrollment site) (get max-capacity site)) ERR-ENROLLMENT-FULL)

    ;; Record enrollment
    (map-set patient-enrollments
      { enrollment-id: enrollment-id }
      {
        patient-id: patient-id,
        trial-id: trial-id,
        site-id: site-id,
        enrollment-date: block-height,
        enrolled-by: tx-sender,
        randomization-code: randomization-code,
        treatment-arm: treatment-arm,
        status: "enrolled"
      }
    )

    ;; Update counters
    (map-set trial-site-assignments
      { trial-id: trial-id, site-id: site-id }
      (merge assignment {
        current-enrollment: (+ (get current-enrollment assignment) u1)
      })
    )

    (map-set research-sites
      { site-id: site-id }
      (merge site {
        current-enrollment: (+ (get current-enrollment site) u1)
      })
    )

    (var-set next-enrollment-id (+ enrollment-id u1))
    (ok enrollment-id)
  )
)

;; Inter-Site Communication
(define-public (send-site-message (target-site-id uint) (message-id uint) (message-hash (buff 32)) (message-type (string-ascii 50)) (priority uint) (requires-response bool))
  (let
    (
      (coordinator-auth (default-to { is-authorized: false, site-id: u0, permissions: u0 } (map-get? authorized-coordinators { coordinator: tx-sender })))
      (sender-site-id (get site-id coordinator-auth))
    )
    (asserts! (get is-authorized coordinator-auth) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? research-sites { site-id: target-site-id })) ERR-SITE-NOT-FOUND)
    (asserts! (and (>= priority u1) (<= priority u5)) ERR-INVALID-INPUT)

    (map-set site-communications
      { site-id: target-site-id, message-id: message-id }
      {
        sender-site: sender-site-id,
        message-hash: message-hash,
        message-type: message-type,
        timestamp: block-height,
        priority: priority,
        requires-response: requires-response
      }
    )
    (ok true)
  )
)

;; Data Synchronization
(define-public (initiate-data-sync (trial-id uint) (sync-id uint) (participating-sites (list 10 uint)) (data-hash (buff 32)))
  (let
    (
      (coordinator-auth (default-to { is-authorized: false, site-id: u0, permissions: u0 } (map-get? authorized-coordinators { coordinator: tx-sender })))
    )
    (asserts! (get is-authorized coordinator-auth) ERR-NOT-AUTHORIZED)
    (asserts! (> (len participating-sites) u0) ERR-INVALID-INPUT)

    (map-set data-synchronization
      { trial-id: trial-id, sync-id: sync-id }
      {
        sync-date: block-height,
        participating-sites: participating-sites,
        data-hash: data-hash,
        sync-status: "initiated",
        initiated-by: tx-sender
      }
    )
    (ok true)
  )
)

;; Enrollment Statistics
(define-public (update-enrollment-rate (trial-id uint) (site-id uint) (new-rate uint))
  (let
    (
      (assignment (unwrap! (map-get? trial-site-assignments { trial-id: trial-id, site-id: site-id }) ERR-TRIAL-NOT-FOUND))
      (coordinator-auth (default-to { is-authorized: false, site-id: u0, permissions: u0 } (map-get? authorized-coordinators { coordinator: tx-sender })))
    )
    (asserts! (get is-authorized coordinator-auth) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get site-id coordinator-auth) site-id) ERR-NOT-AUTHORIZED)

    (map-set trial-site-assignments
      { trial-id: trial-id, site-id: site-id }
      (merge assignment { enrollment-rate: new-rate })
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-research-site (site-id uint))
  (map-get? research-sites { site-id: site-id })
)

(define-read-only (get-trial-site-assignment (trial-id uint) (site-id uint))
  (map-get? trial-site-assignments { trial-id: trial-id, site-id: site-id })
)

(define-read-only (get-patient-enrollment (enrollment-id uint))
  (map-get? patient-enrollments { enrollment-id: enrollment-id })
)

(define-read-only (get-site-message (site-id uint) (message-id uint))
  (map-get? site-communications { site-id: site-id, message-id: message-id })
)

(define-read-only (get-data-sync (trial-id uint) (sync-id uint))
  (map-get? data-synchronization { trial-id: trial-id, sync-id: sync-id })
)

(define-read-only (is-authorized-coordinator (coordinator principal))
  (default-to false (get is-authorized (map-get? authorized-coordinators { coordinator: coordinator })))
)

(define-read-only (get-coordinator-info (coordinator principal))
  (map-get? authorized-coordinators { coordinator: coordinator })
)

(define-read-only (get-site-enrollment-capacity (site-id uint))
  (match (map-get? research-sites { site-id: site-id })
    site (- (get max-capacity site) (get current-enrollment site))
    u0
  )
)

(define-read-only (get-trial-enrollment-progress (trial-id uint) (site-id uint))
  (match (map-get? trial-site-assignments { trial-id: trial-id, site-id: site-id })
    assignment {
      target: (get target-enrollment assignment),
      current: (get current-enrollment assignment),
      rate: (get enrollment-rate assignment),
      progress: (/ (* (get current-enrollment assignment) u100) (get target-enrollment assignment))
    }
    { target: u0, current: u0, rate: u0, progress: u0 }
  )
)

(define-read-only (get-next-site-id)
  (var-get next-site-id)
)

(define-read-only (get-next-enrollment-id)
  (var-get next-enrollment-id)
)
