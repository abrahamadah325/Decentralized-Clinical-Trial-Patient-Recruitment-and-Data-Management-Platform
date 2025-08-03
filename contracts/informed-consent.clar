;; Informed Consent Tracking Contract
;; Ensures patients understand trial risks and maintains consent documentation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PATIENT-NOT-FOUND (err u201))
(define-constant ERR-TRIAL-NOT-FOUND (err u202))
(define-constant ERR-CONSENT-NOT-FOUND (err u203))
(define-constant ERR-INVALID-INPUT (err u204))
(define-constant ERR-CONSENT-EXPIRED (err u205))

;; Data Variables
(define-data-var next-consent-id uint u1)
(define-data-var consent-validity-period uint u52560) ;; ~1 year in blocks

;; Data Maps
(define-map consent-forms
  { consent-id: uint }
  {
    trial-id: uint,
    version: uint,
    content-hash: (buff 32),
    risks-hash: (buff 32),
    benefits-hash: (buff 32),
    created-at: uint,
    is-active: bool
  }
)

(define-map patient-consents
  { patient-id: uint, trial-id: uint }
  {
    consent-id: uint,
    consent-date: uint,
    witness: principal,
    patient-signature-hash: (buff 32),
    witness-signature-hash: (buff 32),
    is-withdrawn: bool,
    withdrawal-date: (optional uint),
    withdrawal-reason: (optional (string-ascii 200))
  }
)

(define-map consent-updates
  { patient-id: uint, trial-id: uint, update-id: uint }
  {
    old-consent-id: uint,
    new-consent-id: uint,
    update-date: uint,
    reason: (string-ascii 200),
    updated-by: principal
  }
)

(define-map authorized-witnesses
  { witness: principal }
  { is-authorized: bool }
)

;; Authorization Functions
(define-public (authorize-witness (witness principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-witnesses { witness: witness } { is-authorized: true }))
  )
)

(define-public (revoke-witness (witness principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-witnesses { witness: witness } { is-authorized: false }))
  )
)

;; Consent Form Management
(define-public (create-consent-form (trial-id uint) (version uint) (content-hash (buff 32)) (risks-hash (buff 32)) (benefits-hash (buff 32)))
  (let
    (
      (consent-id (var-get next-consent-id))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> version u0) ERR-INVALID-INPUT)
    (map-set consent-forms
      { consent-id: consent-id }
      {
        trial-id: trial-id,
        version: version,
        content-hash: content-hash,
        risks-hash: risks-hash,
        benefits-hash: benefits-hash,
        created-at: block-height,
        is-active: true
      }
    )
    (var-set next-consent-id (+ consent-id u1))
    (ok consent-id)
  )
)

;; Patient Consent Recording
(define-public (record-consent (patient-id uint) (trial-id uint) (consent-id uint) (patient-signature-hash (buff 32)) (witness-signature-hash (buff 32)))
  (let
    (
      (consent-form (unwrap! (map-get? consent-forms { consent-id: consent-id }) ERR-CONSENT-NOT-FOUND))
      (witness-auth (default-to { is-authorized: false } (map-get? authorized-witnesses { witness: tx-sender })))
    )
    (asserts! (get is-authorized witness-auth) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get trial-id consent-form) trial-id) ERR-INVALID-INPUT)
    (asserts! (get is-active consent-form) ERR-INVALID-INPUT)

    (map-set patient-consents
      { patient-id: patient-id, trial-id: trial-id }
      {
        consent-id: consent-id,
        consent-date: block-height,
        witness: tx-sender,
        patient-signature-hash: patient-signature-hash,
        witness-signature-hash: witness-signature-hash,
        is-withdrawn: false,
        withdrawal-date: none,
        withdrawal-reason: none
      }
    )
    (ok true)
  )
)

;; Consent Withdrawal
(define-public (withdraw-consent (patient-id uint) (trial-id uint) (reason (string-ascii 200)))
  (let
    (
      (existing-consent (unwrap! (map-get? patient-consents { patient-id: patient-id, trial-id: trial-id }) ERR-CONSENT-NOT-FOUND))
    )
    (asserts! (not (get is-withdrawn existing-consent)) ERR-INVALID-INPUT)

    (map-set patient-consents
      { patient-id: patient-id, trial-id: trial-id }
      (merge existing-consent {
        is-withdrawn: true,
        withdrawal-date: (some block-height),
        withdrawal-reason: (some reason)
      })
    )
    (ok true)
  )
)

;; Consent Updates
(define-public (update-consent (patient-id uint) (trial-id uint) (new-consent-id uint) (update-id uint) (reason (string-ascii 200)))
  (let
    (
      (existing-consent (unwrap! (map-get? patient-consents { patient-id: patient-id, trial-id: trial-id }) ERR-CONSENT-NOT-FOUND))
      (new-consent-form (unwrap! (map-get? consent-forms { consent-id: new-consent-id }) ERR-CONSENT-NOT-FOUND))
      (witness-auth (default-to { is-authorized: false } (map-get? authorized-witnesses { witness: tx-sender })))
    )
    (asserts! (get is-authorized witness-auth) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-withdrawn existing-consent)) ERR-INVALID-INPUT)
    (asserts! (is-eq (get trial-id new-consent-form) trial-id) ERR-INVALID-INPUT)

    (map-set consent-updates
      { patient-id: patient-id, trial-id: trial-id, update-id: update-id }
      {
        old-consent-id: (get consent-id existing-consent),
        new-consent-id: new-consent-id,
        update-date: block-height,
        reason: reason,
        updated-by: tx-sender
      }
    )
    (ok true)
  )
)

;; Consent Validation
(define-public (validate-consent (patient-id uint) (trial-id uint))
  (let
    (
      (consent (unwrap! (map-get? patient-consents { patient-id: patient-id, trial-id: trial-id }) ERR-CONSENT-NOT-FOUND))
      (consent-form (unwrap! (map-get? consent-forms { consent-id: (get consent-id consent) }) ERR-CONSENT-NOT-FOUND))
      (consent-age (- block-height (get consent-date consent)))
    )
    (asserts! (not (get is-withdrawn consent)) ERR-INVALID-INPUT)
    (asserts! (< consent-age (var-get consent-validity-period)) ERR-CONSENT-EXPIRED)
    (asserts! (get is-active consent-form) ERR-INVALID-INPUT)
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-consent-form (consent-id uint))
  (map-get? consent-forms { consent-id: consent-id })
)

(define-read-only (get-patient-consent (patient-id uint) (trial-id uint))
  (map-get? patient-consents { patient-id: patient-id, trial-id: trial-id })
)

(define-read-only (get-consent-update (patient-id uint) (trial-id uint) (update-id uint))
  (map-get? consent-updates { patient-id: patient-id, trial-id: trial-id, update-id: update-id })
)

(define-read-only (is-authorized-witness (witness principal))
  (default-to false (get is-authorized (map-get? authorized-witnesses { witness: witness })))
)

(define-read-only (is-consent-valid (patient-id uint) (trial-id uint))
  (match (map-get? patient-consents { patient-id: patient-id, trial-id: trial-id })
    consent (let
      (
        (consent-age (- block-height (get consent-date consent)))
      )
      (and
        (not (get is-withdrawn consent))
        (< consent-age (var-get consent-validity-period))
      )
    )
    false
  )
)

(define-read-only (get-next-consent-id)
  (var-get next-consent-id)
)
