;; Adverse Event Reporting Automation Contract
;; Immediately reports serious side effects to regulatory authorities

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-INVALID-INPUT (err u301))
(define-constant ERR-EVENT-NOT-FOUND (err u302))
(define-constant ERR-ALREADY-REPORTED (err u303))

;; Severity Levels
(define-constant SEVERITY-MILD u1)
(define-constant SEVERITY-MODERATE u2)
(define-constant SEVERITY-SEVERE u3)
(define-constant SEVERITY-LIFE-THREATENING u4)
(define-constant SEVERITY-FATAL u5)

;; Causality Assessment
(define-constant CAUSALITY-UNRELATED u1)
(define-constant CAUSALITY-UNLIKELY u2)
(define-constant CAUSALITY-POSSIBLE u3)
(define-constant CAUSALITY-PROBABLE u4)
(define-constant CAUSALITY-DEFINITE u5)

;; Data Variables
(define-data-var next-event-id uint u1)
(define-data-var regulatory-reporting-threshold uint u3) ;; Severe and above

;; Data Maps
(define-map adverse-events
  { event-id: uint }
  {
    patient-id: uint,
    trial-id: uint,
    event-description-hash: (buff 32),
    severity: uint,
    causality: uint,
    onset-date: uint,
    resolution-date: (optional uint),
    reporter: principal,
    reported-at: uint,
    is-serious: bool,
    requires-unblinding: bool
  }
)

(define-map regulatory-reports
  { event-id: uint }
  {
    report-date: uint,
    authority: (string-ascii 50),
    report-id: (string-ascii 100),
    status: (string-ascii 20),
    follow-up-required: bool
  }
)

(define-map event-follow-ups
  { event-id: uint, follow-up-id: uint }
  {
    follow-up-date: uint,
    description-hash: (buff 32),
    reporter: principal,
    outcome-changed: bool,
    new-severity: (optional uint),
    new-causality: (optional uint)
  }
)

(define-map authorized-reporters
  { reporter: principal }
  {
    is-authorized: bool,
    site-id: uint,
    role: (string-ascii 50)
  }
)

(define-map regulatory-authorities
  { authority: (string-ascii 50) }
  {
    contact-info-hash: (buff 32),
    reporting-endpoint: (string-ascii 200),
    is-active: bool
  }
)

;; Authorization Functions
(define-public (authorize-reporter (reporter principal) (site-id uint) (role (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-reporters
      { reporter: reporter }
      { is-authorized: true, site-id: site-id, role: role }
    ))
  )
)

(define-public (revoke-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-reporters
      { reporter: reporter }
      { is-authorized: false, site-id: u0, role: "" }
    ))
  )
)

;; Regulatory Authority Management
(define-public (register-authority (authority (string-ascii 50)) (contact-info-hash (buff 32)) (reporting-endpoint (string-ascii 200)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set regulatory-authorities
      { authority: authority }
      {
        contact-info-hash: contact-info-hash,
        reporting-endpoint: reporting-endpoint,
        is-active: true
      }
    ))
  )
)

;; Adverse Event Reporting
(define-public (report-adverse-event
  (patient-id uint)
  (trial-id uint)
  (event-description-hash (buff 32))
  (severity uint)
  (causality uint)
  (onset-date uint)
  (requires-unblinding bool)
)
  (let
    (
      (event-id (var-get next-event-id))
      (reporter-auth (default-to { is-authorized: false, site-id: u0, role: "" } (map-get? authorized-reporters { reporter: tx-sender })))
      (is-serious (>= severity SEVERITY-SEVERE))
    )
    (asserts! (get is-authorized reporter-auth) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= severity SEVERITY-MILD) (<= severity SEVERITY-FATAL)) ERR-INVALID-INPUT)
    (asserts! (and (>= causality CAUSALITY-UNRELATED) (<= causality CAUSALITY-DEFINITE)) ERR-INVALID-INPUT)
    (asserts! (<= onset-date block-height) ERR-INVALID-INPUT)

    (map-set adverse-events
      { event-id: event-id }
      {
        patient-id: patient-id,
        trial-id: trial-id,
        event-description-hash: event-description-hash,
        severity: severity,
        causality: causality,
        onset-date: onset-date,
        resolution-date: none,
        reporter: tx-sender,
        reported-at: block-height,
        is-serious: is-serious,
        requires-unblinding: requires-unblinding
      }
    )
    (var-set next-event-id (+ event-id u1))

    ;; Auto-trigger regulatory reporting for serious events
    (if (>= severity (var-get regulatory-reporting-threshold))
      (try! (trigger-regulatory-report event-id))
      (ok true)
    )
    (ok event-id)
  )
)

;; Regulatory Reporting
(define-public (trigger-regulatory-report (event-id uint))
  (let
    (
      (event (unwrap! (map-get? adverse-events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
      (existing-report (map-get? regulatory-reports { event-id: event-id }))
    )
    (asserts! (is-none existing-report) ERR-ALREADY-REPORTED)
    (asserts! (get is-serious event) ERR-INVALID-INPUT)

    (map-set regulatory-reports
      { event-id: event-id }
      {
        report-date: block-height,
        authority: "FDA",
        report-id: (concat "AE-" (int-to-ascii event-id)),
        status: "submitted",
        follow-up-required: true
      }
    )
    (ok true)
  )
)

;; Event Follow-up
(define-public (add-follow-up (event-id uint) (follow-up-id uint) (description-hash (buff 32)) (outcome-changed bool) (new-severity (optional uint)) (new-causality (optional uint)))
  (let
    (
      (event (unwrap! (map-get? adverse-events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
      (reporter-auth (default-to { is-authorized: false, site-id: u0, role: "" } (map-get? authorized-reporters { reporter: tx-sender })))
    )
    (asserts! (get is-authorized reporter-auth) ERR-NOT-AUTHORIZED)

    (map-set event-follow-ups
      { event-id: event-id, follow-up-id: follow-up-id }
      {
        follow-up-date: block-height,
        description-hash: description-hash,
        reporter: tx-sender,
        outcome-changed: outcome-changed,
        new-severity: new-severity,
        new-causality: new-causality
      }
    )

    ;; Update main event if outcome changed
    (if outcome-changed
      (map-set adverse-events
        { event-id: event-id }
        (merge event {
          severity: (default-to (get severity event) new-severity),
          causality: (default-to (get causality event) new-causality)
        })
      )
      (ok true)
    )
    (ok true)
  )
)

;; Event Resolution
(define-public (resolve-event (event-id uint) (resolution-date uint))
  (let
    (
      (event (unwrap! (map-get? adverse-events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
      (reporter-auth (default-to { is-authorized: false, site-id: u0, role: "" } (map-get? authorized-reporters { reporter: tx-sender })))
    )
    (asserts! (get is-authorized reporter-auth) ERR-NOT-AUTHORIZED)
    (asserts! (>= resolution-date (get onset-date event)) ERR-INVALID-INPUT)
    (asserts! (is-none (get resolution-date event)) ERR-INVALID-INPUT)

    (map-set adverse-events
      { event-id: event-id }
      (merge event { resolution-date: (some resolution-date) })
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-adverse-event (event-id uint))
  (map-get? adverse-events { event-id: event-id })
)

(define-read-only (get-regulatory-report (event-id uint))
  (map-get? regulatory-reports { event-id: event-id })
)

(define-read-only (get-event-follow-up (event-id uint) (follow-up-id uint))
  (map-get? event-follow-ups { event-id: event-id, follow-up-id: follow-up-id })
)

(define-read-only (is-authorized-reporter (reporter principal))
  (default-to false (get is-authorized (map-get? authorized-reporters { reporter: reporter })))
)

(define-read-only (get-reporter-info (reporter principal))
  (map-get? authorized-reporters { reporter: reporter })
)

(define-read-only (requires-regulatory-reporting (severity uint))
  (>= severity (var-get regulatory-reporting-threshold))
)

(define-read-only (get-next-event-id)
  (var-get next-event-id)
)

(define-read-only (get-regulatory-authority (authority (string-ascii 50)))
  (map-get? regulatory-authorities { authority: authority })
)
