;; Error codes:
;; u1 - Not contract owner
;; u2 - Token type already exists
;; u3 - Token type not found
;; u4 - Exceeds maximum supply
;; u5 - Token properties not found
;; u6 - Insufficient balance
;; u7 - Invalid listing
;; u8 - Listing not found
;; u9 - Insufficient payment
;; u10 - Transfer failed
;; u11 - Invalid input parameters
;; u12 - Invalid token ID
;; u13 - Invalid price

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-not-owner (err u1))
(define-constant err-token-exists (err u2))
(define-constant err-no-token (err u3))
(define-constant err-max-supply (err u4))
(define-constant err-no-properties (err u5))
(define-constant err-insufficient-balance (err u6))
(define-constant err-invalid-listing (err u7))
(define-constant err-no-listing (err u8))
(define-constant err-insufficient-payment (err u9))
(define-constant err-transfer-failed (err u10))
(define-constant err-invalid-params (err u11))
(define-constant err-invalid-token (err u12))
(define-constant err-invalid-price (err u13))

;; Data Variables
(define-data-var next-token-id uint u1)
(define-data-var next-listing-id uint u1)

;; Data Maps
(define-map token-types
    { token-id: uint }
    {
        is-fungible: bool,
        max-supply: uint,
        current-supply: uint,
        metadata-uri: (string-ascii 256),
        creator: principal
    }
)

(define-map token-balances
    { owner: principal, token-id: uint }
    { amount: uint }
)

(define-map token-properties
    { token-id: uint }
    {
        level: uint,
        experience: uint,
        last-modified: uint,
        rarity: (string-ascii 20)
    }
)

(define-map marketplace-listings
    { listing-id: uint }
    {
        seller: principal,
        token-id: uint,
        amount: uint,
        price: uint
    }
)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

(define-private (validate-token-id (token-id uint))
    (and 
        (> token-id u0)
        (< token-id (var-get next-token-id))
    )
)

(define-private (validate-price (price uint))
    (> price u0)
)

(define-private (validate-listing-id (listing-id uint))
    (and 
        (> listing-id u0)
        (< listing-id (var-get next-listing-id))
    )
)

(define-private (validate-max-supply (max-supply uint))
    (> max-supply u0)
)

(define-private (transfer-token 
    (token-id uint)
    (amount uint)
    (sender principal)
    (recipient principal)
)
    (let (
        (sender-balance (default-to { amount: u0 } (map-get? token-balances { owner: sender, token-id: token-id })))
        (recipient-balance (default-to { amount: u0 } (map-get? token-balances { owner: recipient, token-id: token-id })))
    )
        (asserts! (validate-token-id token-id) err-invalid-token)
        (if (>= (get amount sender-balance) amount)
            (begin
                (map-set token-balances
                    { owner: sender, token-id: token-id }
                    { amount: (- (get amount sender-balance) amount) }
                )
                (map-set token-balances
                    { owner: recipient, token-id: token-id }
                    { amount: (+ (get amount recipient-balance) amount) }
                )
                (ok true)
            )
            err-insufficient-balance
        )
    )
)

;; Public Functions - Token Management
(define-public (create-token-type 
    (is-fungible bool)
    (max-supply uint)
    (metadata-uri (string-ascii 256))
)
    (let ((token-id (var-get next-token-id)))
        (asserts! (is-contract-owner) err-not-owner)
        (asserts! (validate-max-supply max-supply) err-invalid-params)
        (asserts! (is-none (map-get? token-types { token-id: token-id })) err-token-exists)
        (asserts! (not (is-eq metadata-uri "")) err-invalid-params)
        
        (map-set token-types
            { token-id: token-id }
            {
                is-fungible: is-fungible,
                max-supply: max-supply,
                current-supply: u0,
                metadata-uri: metadata-uri,
                creator: tx-sender
            }
        )
        (map-set token-properties
            { token-id: token-id }
            {
                level: u1,
                experience: u0,
                last-modified: block-height,
                rarity: "common"
            }
        )
        (var-set next-token-id (+ token-id u1))
        (ok token-id)
    )
)

(define-public (mint 
    (token-id uint)
    (amount uint)
    (recipient principal)
)
    (let (
        (token-type (unwrap! (map-get? token-types { token-id: token-id }) err-no-token))
        (current-balance (default-to { amount: u0 } (map-get? token-balances { owner: recipient, token-id: token-id })))
    )
        (asserts! (is-contract-owner) err-not-owner)
        (asserts! (validate-token-id token-id) err-invalid-token)
        (asserts! (> amount u0) err-invalid-params)
        (asserts! (<= (+ (get current-supply token-type) amount) (get max-supply token-type)) err-max-supply)
        
        (map-set token-balances
            { owner: recipient, token-id: token-id }
            { amount: (+ (get amount current-balance) amount) }
        )
        (map-set token-types
            { token-id: token-id }
            (merge token-type { current-supply: (+ (get current-supply token-type) amount) })
        )
        (ok true)
    )
)

;; Public Functions - Game Mechanics
(define-public (level-up-token
    (token-id uint)
)
    (let (
        (properties (unwrap! (map-get? token-properties { token-id: token-id }) err-no-properties))
        (owner-balance (unwrap! (map-get? token-balances { owner: tx-sender, token-id: token-id }) err-insufficient-balance))
    )
        (asserts! (validate-token-id token-id) err-invalid-token)
        (asserts! (> (get amount owner-balance) u0) err-insufficient-balance)
        (ok (map-set token-properties
            { token-id: token-id }
            (merge properties {
                level: (+ (get level properties) u1),
                experience: u0,
                last-modified: block-height
            })
        ))
    )
)

(define-public (add-experience
    (token-id uint)
    (exp-amount uint)
)
    (let (
        (properties (unwrap! (map-get? token-properties { token-id: token-id }) err-no-properties))
        (owner-balance (unwrap! (map-get? token-balances { owner: tx-sender, token-id: token-id }) err-insufficient-balance))
    )
        (asserts! (validate-token-id token-id) err-invalid-token)
        (asserts! (> exp-amount u0) err-invalid-params)
        (asserts! (> (get amount owner-balance) u0) err-insufficient-balance)
        (ok (map-set token-properties
            { token-id: token-id }
            (merge properties {
                experience: (+ (get experience properties) exp-amount),
                last-modified: block-height
            })
        ))
    )
)

;; Public Functions - Marketplace
(define-public (create-listing
    (token-id uint)
    (amount uint)
    (price uint)
)
    (let (
        (listing-id (var-get next-listing-id))
        (balance (unwrap! (map-get? token-balances { owner: tx-sender, token-id: token-id }) err-insufficient-balance))
    )
        (asserts! (validate-token-id token-id) err-invalid-token)
        (asserts! (validate-price price) err-invalid-price)
        (asserts! (> amount u0) err-invalid-params)
        (asserts! (>= (get amount balance) amount) err-insufficient-balance)
        
        (map-set marketplace-listings
            { listing-id: listing-id }
            {
                seller: tx-sender,
                token-id: token-id,
                amount: amount,
                price: price
            }
        )
        (var-set next-listing-id (+ listing-id u1))
        (ok listing-id)
    )
)

(define-public (cancel-listing
    (listing-id uint)
)
    (let (
        (listing (unwrap! (map-get? marketplace-listings { listing-id: listing-id }) err-no-listing))
    )
        (asserts! (validate-listing-id listing-id) err-invalid-params)
        (asserts! (is-eq (get seller listing) tx-sender) err-not-owner)
        (map-delete marketplace-listings { listing-id: listing-id })
        (ok true)
    )
)

(define-public (purchase-listing
    (listing-id uint)
)
    (let (
        (listing (unwrap! (map-get? marketplace-listings { listing-id: listing-id }) err-no-listing))
        (price (get price listing))
    )
        (asserts! (validate-listing-id listing-id) err-invalid-params)
        (try! (stx-transfer? price tx-sender (get seller listing)))
        (try! (transfer-token
            (get token-id listing)
            (get amount listing)
            (get seller listing)
            tx-sender
        ))
        (map-delete marketplace-listings { listing-id: listing-id })
        (ok true)
    )
)

;; Read-Only Functions
(define-read-only (get-token-type (token-id uint))
    (map-get? token-types { token-id: token-id })
)

(define-read-only (get-token-properties (token-id uint))
    (map-get? token-properties { token-id: token-id })
)

(define-read-only (get-balance (token-id uint) (owner principal))
    (default-to { amount: u0 }
        (map-get? token-balances { owner: owner, token-id: token-id })
    )
)

(define-read-only (get-listing (listing-id uint))
    (map-get? marketplace-listings { listing-id: listing-id })
)