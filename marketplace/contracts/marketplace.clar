;; Advanced marketplace functionality for MultiVerse Assets with auctions and royalties

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-ALREADY-LISTED (err u1001))
(define-constant ERR-NOT-LISTED (err u1002))
(define-constant ERR-AUCTION-ACTIVE (err u1003))
(define-constant ERR-AUCTION-ENDED (err u1004))
(define-constant ERR-INVALID-PRICE (err u1005))
(define-constant ERR-LOW-BID (err u1006))
(define-constant ERR-NOT-OWNER (err u1007))
(define-constant ERR-INVALID-TOKEN (err u1008))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1009))
(define-constant ERR-LISTING-EXPIRED (err u1010))
(define-constant ERR-INVALID-ROYALTY (err u1011))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ROYALTY-DENOMINATOR u10000)  ;; Base for royalty calculations (100.00%)
(define-constant MIN-AUCTION-DURATION u1440)  ;; Minimum auction duration in blocks (~10 days)
(define-constant MAX-ROYALTY-RATE u2000)      ;; Maximum royalty rate (20.00%)

;; Data Variables
(define-data-var listing-nonce uint u0)
(define-data-var auction-nonce uint u0)
(define-data-var platform-fee uint u250)      ;; 2.50% platform fee

;; Principal Variables
(define-data-var platform-address principal CONTRACT-OWNER)

;; Listing Types
(define-constant LISTING-TYPE-FIXED "fixed")
(define-constant LISTING-TYPE-AUCTION "auction")

;; Data Maps
(define-map listings
    { listing-id: uint }
    {
        seller: principal,
        token-id: uint,
        amount: uint,
        price: uint,
        listing-type: (string-ascii 10),
        expiry: uint,
        royalty-recipient: principal,
        royalty-rate: uint
    }
)

(define-map auctions
    { auction-id: uint }
    {
        listing-id: uint,
        highest-bid: uint,
        highest-bidder: (optional principal),
        end-block: uint,
        reserve-price: uint,
        min-increment: uint
    }
)

(define-map auction-bids
    { auction-id: uint, bidder: principal }
    { bid-amount: uint }
)

;; Private Functions
(define-private (validate-listing 
    (listing-id uint)
    (listing {
        seller: principal,
        token-id: uint,
        amount: uint,
        price: uint,
        listing-type: (string-ascii 10),
        expiry: uint,
        royalty-recipient: principal,
        royalty-rate: uint
    })
)
    (and
        (is-eq (get listing-type listing) LISTING-TYPE-FIXED)
        (> (get amount listing) u0)
        (> (get price listing) u0)
        (<= (get royalty-rate listing) MAX-ROYALTY-RATE)
        (>= (get expiry listing) block-height)
    )
)

(define-private (calculate-platform-fee (price uint))
    (/ (* price (var-get platform-fee)) ROYALTY-DENOMINATOR)
)

(define-private (calculate-royalty (price uint) (royalty-rate uint))
    (/ (* price royalty-rate) ROYALTY-DENOMINATOR)
)

;; Public Functions - Fixed Price Listings
(define-public (create-fixed-listing
    (token-id uint)
    (amount uint)
    (price uint)
    (expiry uint)
    (royalty-rate uint)
)
    (let
        (
            (listing-id (var-get listing-nonce))
            (seller-balance (contract-call? .asset get-balance token-id tx-sender))
        )
        (asserts! (>= (get amount seller-balance) amount) ERR-INSUFFICIENT-BALANCE)
        (asserts! (>= expiry (+ block-height MIN-AUCTION-DURATION)) ERR-LISTING-EXPIRED)
        (asserts! (<= royalty-rate MAX-ROYALTY-RATE) ERR-INVALID-ROYALTY)
        
        ;; Create listing
        (map-set listings
            { listing-id: listing-id }
            {
                seller: tx-sender,
                token-id: token-id,
                amount: amount,
                price: price,
                listing-type: LISTING-TYPE-FIXED,
                expiry: expiry,
                royalty-recipient: tx-sender,
                royalty-rate: royalty-rate
            }
        )
        
        ;; Increment nonce
        (var-set listing-nonce (+ listing-id u1))
        (ok listing-id)
    )
)

(define-public (cancel-fixed-listing (listing-id uint))
    (let
        (
            (listing (unwrap! (map-get? listings {listing-id: listing-id}) ERR-NOT-LISTED))
        )
        (asserts! (is-eq (get seller listing) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get listing-type listing) LISTING-TYPE-FIXED) ERR-AUCTION-ACTIVE)
        
        ;; Remove listing
        (map-delete listings {listing-id: listing-id})
        (ok true)
    )
)

(define-public (purchase-listing (listing-id uint))
    (let
        (
            (listing (unwrap! (map-get? listings {listing-id: listing-id}) ERR-NOT-LISTED))
            (price (get price listing))
            (seller (get seller listing))
            (royalty-rate (get royalty-rate listing))
            (royalty-recipient (get royalty-recipient listing))
            (platform-fee-amount (calculate-platform-fee price))
            (royalty-amount (calculate-royalty price royalty-rate))
            (seller-amount (- price (+ platform-fee-amount royalty-amount)))
            (token-id (get token-id listing))
            (amount (get amount listing))
        )
        ;; Validate listing
        (asserts! (is-eq (get listing-type listing) LISTING-TYPE-FIXED) ERR-AUCTION-ACTIVE)
        (asserts! (<= block-height (get expiry listing)) ERR-LISTING-EXPIRED)
        
        ;; Process payments
        (try! (stx-transfer? platform-fee-amount tx-sender (var-get platform-address)))
        (try! (stx-transfer? royalty-amount tx-sender royalty-recipient))
        (try! (stx-transfer? seller-amount tx-sender seller))
        
        ;; Get current balances for verification
        (let ((seller-balance (contract-call? .asset get-balance token-id seller)))
            (asserts! (>= (get amount seller-balance) amount) ERR-INSUFFICIENT-BALANCE)
            ;; Call the asset contract purchase function
            (try! (contract-call? .asset purchase-listing listing-id))
            ;; Remove listing after successful purchase
            (map-delete listings {listing-id: listing-id})
            (ok true)
        )
    )
)

;; Public Functions - Auction Listings
(define-public (create-auction
    (token-id uint)
    (amount uint)
    (reserve-price uint)
    (min-increment uint)
    (duration uint)
    (royalty-rate uint)
)
    (let
        (
            (listing-id (var-get listing-nonce))
            (auction-id (var-get auction-nonce))
            (seller-balance (contract-call? .asset get-balance token-id tx-sender))
        )
        (asserts! (>= (get amount seller-balance) amount) ERR-INSUFFICIENT-BALANCE)
        (asserts! (>= duration MIN-AUCTION-DURATION) ERR-LISTING-EXPIRED)
        (asserts! (<= royalty-rate MAX-ROYALTY-RATE) ERR-INVALID-ROYALTY)
        
        ;; Create listing
        (map-set listings
            { listing-id: listing-id }
            {
                seller: tx-sender,
                token-id: token-id,
                amount: amount,
                price: reserve-price,
                listing-type: LISTING-TYPE-AUCTION,
                expiry: (+ block-height duration),
                royalty-recipient: tx-sender,
                royalty-rate: royalty-rate
            }
        )
        
        ;; Create auction
        (map-set auctions
            { auction-id: auction-id }
            {
                listing-id: listing-id,
                highest-bid: u0,
                highest-bidder: none,
                end-block: (+ block-height duration),
                reserve-price: reserve-price,
                min-increment: min-increment
            }
        )
        
        ;; Increment nonces
        (var-set listing-nonce (+ listing-id u1))
        (var-set auction-nonce (+ auction-id u1))
        (ok auction-id)
    )
)

(define-public (place-bid (auction-id uint) (bid-amount uint))
    (let
        (
            (auction (unwrap! (map-get? auctions {auction-id: auction-id}) ERR-NOT-LISTED))
            (listing (unwrap! (map-get? listings {listing-id: (get listing-id auction)}) ERR-NOT-LISTED))
            (current-highest-bid (get highest-bid auction))
            (min-valid-bid (+ current-highest-bid (get min-increment auction)))
        )
        ;; Validate auction
        (asserts! (< block-height (get end-block auction)) ERR-AUCTION-ENDED)
        (asserts! (>= bid-amount (get reserve-price auction)) ERR-LOW-BID)
        (asserts! (> bid-amount min-valid-bid) ERR-LOW-BID)
        
        ;; Process bid
        (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))
        
        ;; Refund previous bidder if exists
        (match (get highest-bidder auction) prev-bidder 
            (try! (as-contract (stx-transfer? current-highest-bid (as-contract tx-sender) prev-bidder)))
            true
        )
        
        ;; Update auction
        (map-set auctions
            { auction-id: auction-id }
            (merge auction {
                highest-bid: bid-amount,
                highest-bidder: (some tx-sender)
            })
        )
        
        (map-set auction-bids
            { auction-id: auction-id, bidder: tx-sender }
            { bid-amount: bid-amount }
        )
        
        (ok true)
    )
)

(define-public (finalize-auction (auction-id uint))
    (let
        (
            (auction (unwrap! (map-get? auctions {auction-id: auction-id}) ERR-NOT-LISTED))
            (listing (unwrap! (map-get? listings {listing-id: (get listing-id auction)}) ERR-NOT-LISTED))
            (highest-bid (get highest-bid auction))
            (winner (unwrap! (get highest-bidder auction) ERR-NOT-LISTED))
            (platform-fee-amount (calculate-platform-fee highest-bid))
            (royalty-amount (calculate-royalty highest-bid (get royalty-rate listing)))
            (seller-amount (- highest-bid (+ platform-fee-amount royalty-amount)))
        )
        ;; Validate auction
        (asserts! (>= block-height (get end-block auction)) ERR-AUCTION-ACTIVE)
        
        ;; Process payments
        (try! (as-contract (stx-transfer? platform-fee-amount (as-contract tx-sender) (var-get platform-address))))
        (try! (as-contract (stx-transfer? royalty-amount (as-contract tx-sender) (get royalty-recipient listing))))
        (try! (as-contract (stx-transfer? seller-amount (as-contract tx-sender) (get seller listing))))
        
        ;; Call the asset contract purchase function
        (try! (contract-call? .asset purchase-listing (get listing-id auction)))
        
        ;; Cleanup
        (map-delete auctions {auction-id: auction-id})
        (map-delete listings {listing-id: (get listing-id auction)})
        
        (ok true)
    )
)

;; Read-Only Functions
(define-read-only (get-listing (listing-id uint))
    (map-get? listings {listing-id: listing-id})
)

(define-read-only (get-auction (auction-id uint))
    (map-get? auctions {auction-id: auction-id})
)

(define-read-only (get-auction-bid (auction-id uint) (bidder principal))
    (map-get? auction-bids {auction-id: auction-id, bidder: bidder})
)

;; Admin Functions
(define-public (set-platform-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-fee u1000) ERR-INVALID-PRICE)  ;; Max 10% platform fee
        (var-set platform-fee new-fee)
        (ok true)
    )
)

(define-public (set-platform-address (new-address principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set platform-address new-address)
        (ok true)
    )
)