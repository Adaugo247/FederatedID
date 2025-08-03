;; Federated Identity Contract
;; Multi-network identity with delegation and federation support

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-IDENTITY-NOT-FOUND (err u101))
(define-constant ERR-FEDERATION-NOT-FOUND (err u102))
(define-constant ERR-DELEGATE-EXISTS (err u103))
(define-constant ERR-INVALID-FEDERATION (err u104))
(define-constant ERR-INSUFFICIENT-TRUST (err u105))

;; Federation types
(define-constant FEDERATION-TRUSTED u1)
(define-constant FEDERATION-VERIFIED u2)
(define-constant FEDERATION-PARTNER u3)

;; Data structures
(define-map identities
    principal
    {
        primary-did: (string-ascii 256),
        federation-id: (optional uint),
        trust-score: uint,
        delegation-enabled: bool,
        created-at: uint,
        last-sync: uint
    }
)

(define-map federations
    uint
    {
        name: (string-ascii 100),
        admin-contract: principal,
        trust-level: uint,
        member-count: uint,
        cross-chain-support: (list 10 uint),
        metadata-schema: (string-ascii 256),
        created-at: uint,
        active: bool
    }
)

(define-map federation-members
    { federation-id: uint, member: principal }
    {
        role: uint, ;; 1=member, 2=validator, 3=admin
        joined-at: uint,
        reputation-weight: uint,
        last-activity: uint
    }
)

(define-map delegation-rules
    { delegator: principal, delegate: principal }
    {
        permissions: (list 10 uint), ;; What can be delegated
        expiry: uint,
        revocable: bool,
        created-at: uint,
        active: bool
    }
)

(define-map cross-federation-trusts
    { federation-a: uint, federation-b: uint }
    {
        trust-level: uint,
        established-at: uint,
        mutual: bool,
        verification-required: bool
    }
)

(define-map identity-assertions
    { asserter: principal, subject: principal, claim-type: uint }
    {
        federation-verified: bool,
        cross-chain-verified: bool,
        assertion-data: (string-ascii 512),
        confidence: uint,
        timestamp: uint
    }
)

;; Global state
(define-data-var next-federation-id uint u1)
(define-data-var contract-admin principal tx-sender)
(define-data-var federation-registry-fee uint u1000000) ;; 1 STX

;; Federation management
(define-public (create-federation 
    (name (string-ascii 100))
    (admin-contract principal)
    (trust-level uint)
    (cross-chain-support (list 10 uint))
    (metadata-schema (string-ascii 256)))
    (let ((federation-id (var-get next-federation-id)))
        (map-set federations federation-id {
            name: name,
            admin-contract: admin-contract,
            trust-level: trust-level,
            member-count: u0,
            cross-chain-support: cross-chain-support,
            metadata-schema: metadata-schema,
            created-at: block-height,
            active: true
        })
        (var-set next-federation-id (+ federation-id u1))
        (ok federation-id)
    )
)

(define-public (join-federation (federation-id uint))
    (let (
        (federation (unwrap! (map-get? federations federation-id) ERR-FEDERATION-NOT-FOUND))
        (identity (unwrap! (map-get? identities tx-sender) ERR-IDENTITY-NOT-FOUND))
    )
        (asserts! (get active federation) ERR-INVALID-FEDERATION)
        (asserts! (>= (get trust-score identity) (get trust-level federation)) ERR-INSUFFICIENT-TRUST)
        
        (map-set federation-members 
            { federation-id: federation-id, member: tx-sender }
            {
                role: u1, ;; Member role
                joined-at: block-height,
                reputation-weight: (get trust-score identity),
                last-activity: block-height
            }
        )
        
        ;; Update identity federation
        (map-set identities tx-sender
            (merge identity { federation-id: (some federation-id) })
        )
        
        ;; Update federation member count
        (map-set federations federation-id
            (merge federation { member-count: (+ (get member-count federation) u1) })
        )
        
        (ok true)
    )
)

;; Delegation system
(define-public (create-delegation
    (delegate principal)
    (permissions (list 10 uint))
    (expiry uint)
    (revocable bool))
    (let ((identity (unwrap! (map-get? identities tx-sender) ERR-IDENTITY-NOT-FOUND)))
        (asserts! (get delegation-enabled identity) ERR-NOT-AUTHORIZED)
        (asserts! (is-none (map-get? delegation-rules { delegator: tx-sender, delegate: delegate })) ERR-DELEGATE-EXISTS)
        
        (map-set delegation-rules
            { delegator: tx-sender, delegate: delegate }
            {
                permissions: permissions,
                expiry: expiry,
                revocable: revocable,
                created-at: block-height,
                active: true
            }
        )
        (ok true)
    )
)

(define-public (revoke-delegation (delegate principal))
    (let ((delegation (unwrap! (map-get? delegation-rules { delegator: tx-sender, delegate: delegate }) ERR-NOT-AUTHORIZED)))
        (asserts! (get revocable delegation) ERR-NOT-AUTHORIZED)
        (map-set delegation-rules
            { delegator: tx-sender, delegate: delegate }
            (merge delegation { active: false })
        )
        (ok true)
    )
)

;; Cross-federation operations
(define-public (establish-federation-trust
    (other-federation-id uint)
    (trust-level uint)
    (mutual bool)
    (verification-required bool))
    (let (
        (my-identity (unwrap! (map-get? identities tx-sender) ERR-IDENTITY-NOT-FOUND))
        (my-federation-id (unwrap! (get federation-id my-identity) ERR-FEDERATION-NOT-FOUND))
        (my-membership (unwrap! (map-get? federation-members 
            { federation-id: my-federation-id, member: tx-sender }) ERR-NOT-AUTHORIZED))
    )
        (asserts! (>= (get role my-membership) u3) ERR-NOT-AUTHORIZED) ;; Must be admin
        
        (map-set cross-federation-trusts
            { federation-a: my-federation-id, federation-b: other-federation-id }
            {
                trust-level: trust-level,
                established-at: block-height,
                mutual: mutual,
                verification-required: verification-required
            }
        )
        (ok true)
    )
)

;; Identity assertions with federation backing
(define-public (assert-identity-claim
    (subject principal)
    (claim-type uint)
    (assertion-data (string-ascii 512))
    (confidence uint))
    (let (
        (asserter-identity (unwrap! (map-get? identities tx-sender) ERR-IDENTITY-NOT-FOUND))
        (subject-identity (unwrap! (map-get? identities subject) ERR-IDENTITY-NOT-FOUND))
        (asserter-federation (get federation-id asserter-identity))
        (subject-federation (get federation-id subject-identity))
    )
        (map-set identity-assertions
            { asserter: tx-sender, subject: subject, claim-type: claim-type }
            {
                federation-verified: (is-some asserter-federation),
                cross-chain-verified: false, ;; Would be set by cross-chain verification
                assertion-data: assertion-data,
                confidence: confidence,
                timestamp: block-height
            }
        )
        (ok true)
    )
)

;; Sync identity across federations
(define-public (sync-federated-identity (updates (list 10 { key: (string-ascii 50), value: (string-ascii 256) })))
    (let ((identity (unwrap! (map-get? identities tx-sender) ERR-IDENTITY-NOT-FOUND)))
        (map-set identities tx-sender
            (merge identity { last-sync: block-height })
        )
        ;; In practice, would update specific fields based on federation schema
        (ok block-height)
    )
)

;; Read functions
(define-read-only (get-identity (user principal))
    (map-get? identities user)
)

(define-read-only (get-federation (federation-id uint))
    (map-get? federations federation-id)
)

(define-read-only (get-federation-member (federation-id uint) (member principal))
    (map-get? federation-members { federation-id: federation-id, member: member })
)

(define-read-only (get-delegation (delegator principal) (delegate principal))
    (map-get? delegation-rules { delegator: delegator, delegate: delegate })
)

(define-read-only (can-delegate-for (delegate principal) (delegator principal) (permission uint))
    (match (map-get? delegation-rules { delegator: delegator, delegate: delegate })
        delegation (and 
            (get active delegation)
            (> (get expiry delegation) block-height)
            (is-some (index-of (get permissions delegation) permission))
        )
        false
    )
)

(define-read-only (get-cross-federation-trust (federation-a uint) (federation-b uint))
    (map-get? cross-federation-trusts { federation-a: federation-a, federation-b: federation-b })
)

(define-read-only (get-identity-assertion (asserter principal) (subject principal) (claim-type uint))
    (map-get? identity-assertions { asserter: asserter, subject: subject, claim-type: claim-type })
)

;; Utility functions
(define-public (create-identity (primary-did (string-ascii 256)))
    (begin
        (asserts! (is-none (map-get? identities tx-sender)) ERR-NOT-AUTHORIZED)
        (map-set identities tx-sender {
            primary-did: primary-did,
            federation-id: none,
            trust-score: u100,
            delegation-enabled: true,
            created-at: block-height,
            last-sync: block-height
        })
        (ok true)
    )
)