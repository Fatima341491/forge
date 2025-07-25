;; VoteForge - Next-Generation Decentralized Governance Platform
;; Advanced DAO implementation with enhanced security, participation tracking, and democratic features

;; Constants
(define-constant GOVERNANCE_ADMIN tx-sender)
(define-constant ERR-ACCESS_FORBIDDEN (err u300))
(define-constant ERR-PROPOSAL_NOT_EXIST (err u301))
(define-constant ERR-INVALID_CHOICE (err u302))
(define-constant ERR-VOTE_ALREADY_CAST (err u303))
(define-constant ERR-VOTING_PERIOD_ENDED (err u304))
(define-constant ERR-PROPOSAL_EXECUTED (err u305))
(define-constant ERR-PROPOSAL_REJECTED (err u306))
(define-constant ERR-INSUFFICIENT_POWER (err u307))
(define-constant ERR-QUORUM_NOT_MET (err u308))
(define-constant ERR-INVALID_PROPOSAL_DATA (err u309))
(define-constant ERR-PROPOSAL_STILL_ACTIVE (err u310))
(define-constant ERR-INVALID_TITLE (err u311))
(define-constant ERR-INVALID_EXECUTION_DELAY (err u312))
(define-constant ERR-PROPOSAL_COOLDOWN_ACTIVE (err u313))

;; Platform Configuration
(define-constant VOTING_DURATION u288) ;; ~48 hours in blocks
(define-constant MIN_PROPOSAL_POWER u150000) ;; Minimum voting power to create proposal
(define-constant QUORUM_REQUIREMENT u500000) ;; Minimum total votes for valid proposal
(define-constant MIN_TITLE_LENGTH u8)
(define-constant MAX_TITLE_LENGTH u120)
(define-constant MIN_DESCRIPTION_LENGTH u20)
(define-constant MAX_DESCRIPTION_LENGTH u800)
(define-constant MIN_EXECUTION_DELAY u24) ;; Minimum 4 hours in blocks
(define-constant MAX_EXECUTION_DELAY u2160) ;; Maximum ~15 days in blocks
(define-constant PROPOSAL_COOLDOWN u144) ;; ~24 hours cooldown between proposals
(define-constant SUPER_MAJORITY_THRESHOLD u6600) ;; 66% threshold (basis points)

;; System State Variables
(define-data-var total-voting-power uint u2000000)
(define-data-var proposal-counter uint u0)
(define-data-var platform-paused bool false)
(define-data-var last-proposal-timestamp uint u0)
(define-data-var treasury-balance uint u0)

;; Core Data Structures
(define-map governance-proposals
    uint
    {
        title: (string-ascii 120),
        description: (string-ascii 800),
        proposer: principal,
        creation-block: uint,
        voting-deadline: uint,
        votes-for: uint,
        votes-against: uint,
        votes-abstain: uint,
        execution-delay: uint,
        executed: bool,
        cancelled: bool,
        total-participation: uint,
        proposal-type: (string-ascii 32)
    }
)

(define-map voting-power principal uint)
(define-map vote-records 
    {proposal-id: uint, voter: principal} 
    {power-used: uint, vote-choice: (string-ascii 16), timestamp: uint}
)

(define-map delegate-registry principal principal)
(define-map proposal-creators principal (list 20 uint))

;; Private Validation Functions
(define-private (validate-title (title (string-ascii 120)))
    (and 
        (>= (len title) MIN_TITLE_LENGTH)
        (<= (len title) MAX_TITLE_LENGTH)
    )
)

(define-private (validate-description (description (string-ascii 800)))
    (and 
        (>= (len description) MIN_DESCRIPTION_LENGTH)
        (<= (len description) MAX_DESCRIPTION_LENGTH)
    )
)

(define-private (validate-execution-delay (delay uint))
    (and 
        (>= delay MIN_EXECUTION_DELAY)
        (<= delay MAX_EXECUTION_DELAY)
    )
)

(define-private (is-governance-admin)
    (is-eq tx-sender GOVERNANCE_ADMIN)
)

(define-private (calculate-vote-percentage (votes-for uint) (total-votes uint))
    (if (is-eq total-votes u0)
        u0
        (/ (* votes-for u10000) total-votes)
    )
)

(define-private (update-creator-history (creator principal) (proposal-id uint))
    (let
        (
            (current-history (default-to (list) (map-get? proposal-creators creator)))
        )
        (map-set proposal-creators creator 
            (unwrap-panic (as-max-len? (append current-history proposal-id) u20))
        )
    )
)

;; Emergency Controls
(define-public (toggle-platform-pause (pause-state bool))
    (begin
        (asserts! (is-governance-admin) ERR-ACCESS_FORBIDDEN)
        (var-set platform-paused pause-state)
        (ok true)
    )
)

(define-public (emergency-cancel-proposal (proposal-id uint))
    (begin
        (asserts! (is-governance-admin) ERR-ACCESS_FORBIDDEN)
        (match (map-get? governance-proposals proposal-id)
            proposal-data
            (begin
                (map-set governance-proposals proposal-id
                    (merge proposal-data {cancelled: true})
                )
                (ok true)
            )
            ERR-PROPOSAL_NOT_EXIST
        )
    )
)

;; Voting Power Management
(define-public (delegate-voting-power (delegate principal))
    (begin
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        (asserts! (not (is-eq tx-sender delegate)) ERR-INVALID_CHOICE)
        
        (map-set delegate-registry tx-sender delegate)
        (ok true)
    )
)

(define-public (revoke-delegation)
    (begin
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        
        (map-delete delegate-registry tx-sender)
        (ok true)
    )
)

(define-public (transfer-voting-power (amount uint) (recipient principal))
    (begin
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        (asserts! (> amount u0) ERR-INSUFFICIENT_POWER)
        (asserts! (not (is-eq tx-sender recipient)) ERR-INVALID_CHOICE)
        
        (let ((sender-power (default-to u0 (map-get? voting-power tx-sender))))
            (asserts! (>= sender-power amount) ERR-INSUFFICIENT_POWER)
            
            (map-set voting-power tx-sender (- sender-power amount))
            (map-set voting-power recipient (+ (default-to u0 (map-get? voting-power recipient)) amount))
            (ok true)
        )
    )
)

;; Enhanced Proposal Creation
(define-public (create-governance-proposal (title (string-ascii 120)) (description (string-ascii 800)) (execution-delay uint) (proposal-type (string-ascii 32)))
    (begin
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        (asserts! (validate-title title) ERR-INVALID_TITLE)
        (asserts! (validate-description description) ERR-INVALID_PROPOSAL_DATA)
        (asserts! (validate-execution-delay execution-delay) ERR-INVALID_EXECUTION_DELAY)
        (asserts! (>= (get-effective-voting-power tx-sender) MIN_PROPOSAL_POWER) ERR-ACCESS_FORBIDDEN)
        (asserts! (>= (- block-height (var-get last-proposal-timestamp)) PROPOSAL_COOLDOWN) ERR-PROPOSAL_COOLDOWN_ACTIVE)
        
        (let (
            (proposal-id (var-get proposal-counter))
            (creation-block block-height)
            (deadline (+ block-height VOTING_DURATION))
        )
            (map-set governance-proposals proposal-id {
                title: title,
                description: description,
                proposer: tx-sender,
                creation-block: creation-block,
                voting-deadline: deadline,
                votes-for: u0,
                votes-against: u0,
                votes-abstain: u0,
                execution-delay: execution-delay,
                executed: false,
                cancelled: false,
                total-participation: u0,
                proposal-type: proposal-type
            })
            (update-creator-history tx-sender proposal-id)
            (var-set proposal-counter (+ proposal-id u1))
            (var-set last-proposal-timestamp block-height)
            (ok proposal-id)
        )
    )
)

;; Advanced Voting System
(define-public (cast-governance-vote (proposal-id uint) (vote-choice (string-ascii 16)))
    (begin
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        
        (let (
            (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-PROPOSAL_NOT_EXIST))
            (voter-power (get-effective-voting-power tx-sender))
            (current-time block-height)
        )
            (asserts! (>= current-time (get creation-block proposal)) ERR-INVALID_CHOICE)
            (asserts! (<= current-time (get voting-deadline proposal)) ERR-VOTING_PERIOD_ENDED)
            (asserts! (not (get cancelled proposal)) ERR-VOTING_PERIOD_ENDED)
            (asserts! (is-none (map-get? vote-records {proposal-id: proposal-id, voter: tx-sender})) ERR-VOTE_ALREADY_CAST)
            (asserts! (> voter-power u0) ERR-ACCESS_FORBIDDEN)
            (asserts! (or (is-eq vote-choice "for") (is-eq vote-choice "against") (is-eq vote-choice "abstain")) ERR-INVALID_CHOICE)
            
            ;; Record the vote
            (map-set vote-records {proposal-id: proposal-id, voter: tx-sender}
                {power-used: voter-power, vote-choice: vote-choice, timestamp: current-time})
            
            ;; Update proposal vote counts
            (map-set governance-proposals proposal-id 
                (merge proposal {
                    votes-for: (if (is-eq vote-choice "for") (+ (get votes-for proposal) voter-power) (get votes-for proposal)),
                    votes-against: (if (is-eq vote-choice "against") (+ (get votes-against proposal) voter-power) (get votes-against proposal)),
                    votes-abstain: (if (is-eq vote-choice "abstain") (+ (get votes-abstain proposal) voter-power) (get votes-abstain proposal)),
                    total-participation: (+ (get total-participation proposal) voter-power)
                }))
            
            (ok true)
        )
    )
)

;; Proposal Execution with Enhanced Checks
(define-public (execute-governance-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-PROPOSAL_NOT_EXIST))
        (total-votes (+ (+ (get votes-for proposal) (get votes-against proposal)) (get votes-abstain proposal)))
        (approval-rate (calculate-vote-percentage (get votes-for proposal) (+ (get votes-for proposal) (get votes-against proposal))))
    )
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        (asserts! (> block-height (+ (get voting-deadline proposal) (get execution-delay proposal))) ERR-PROPOSAL_STILL_ACTIVE)
        (asserts! (not (get executed proposal)) ERR-PROPOSAL_EXECUTED)
        (asserts! (not (get cancelled proposal)) ERR-VOTING_PERIOD_ENDED)
        (asserts! (>= (get total-participation proposal) QUORUM_REQUIREMENT) ERR-QUORUM_NOT_MET)
        (asserts! (>= approval-rate SUPER_MAJORITY_THRESHOLD) ERR-PROPOSAL_REJECTED)
        
        (begin
            (map-set governance-proposals proposal-id (merge proposal {executed: true}))
            ;; Custom execution logic would go here based on proposal-type
            (ok true)
        )
    )
)

;; Proposal Withdrawal
(define-public (withdraw-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? governance-proposals proposal-id) ERR-PROPOSAL_NOT_EXIST))
    )
        (asserts! (or (is-governance-admin) (is-eq tx-sender (get proposer proposal))) ERR-ACCESS_FORBIDDEN)
        (asserts! (not (get executed proposal)) ERR-PROPOSAL_EXECUTED)
        (asserts! (<= block-height (get voting-deadline proposal)) ERR-VOTING_PERIOD_ENDED)
        
        (map-set governance-proposals proposal-id (merge proposal {cancelled: true}))
        (ok true)
    )
)

;; Batch Operations
(define-public (batch-vote (proposal-ids (list 10 uint)) (vote-choices (list 10 (string-ascii 16))))
    (begin
        (asserts! (is-eq (len proposal-ids) (len vote-choices)) ERR-INVALID_PROPOSAL_DATA)
        (asserts! (not (var-get platform-paused)) ERR-ACCESS_FORBIDDEN)
        
        (ok (map batch-vote-helper proposal-ids vote-choices))
    )
)

(define-private (batch-vote-helper (proposal-id uint) (vote-choice (string-ascii 16)))
    (match (cast-governance-vote proposal-id vote-choice)
        success true
        error false
    )
)

;; Treasury Management
(define-public (update-treasury-balance (new-balance uint))
    (begin
        (asserts! (is-governance-admin) ERR-ACCESS_FORBIDDEN)
        (var-set treasury-balance new-balance)
        (ok true)
    )
)

;; Enhanced Read-Only Functions
(define-read-only (get-governance-proposal (proposal-id uint))
    (map-get? governance-proposals proposal-id)
)

(define-read-only (get-vote-record (proposal-id uint) (voter principal))
    (map-get? vote-records {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-voting-power (account principal))
    (default-to u0 (map-get? voting-power account))
)

(define-read-only (get-delegate (delegator principal))
    (map-get? delegate-registry delegator)
)

(define-read-only (get-effective-voting-power (account principal))
    (let
        (
            (base-power (default-to u0 (map-get? voting-power account)))
            (delegated-power 
                (match (map-get? delegate-registry account)
                    delegate (default-to u0 (map-get? voting-power delegate))
                    base-power
                )
            )
        )
        (+ base-power delegated-power)
    )
)

(define-read-only (get-proposal-status (proposal-id uint))
    (match (map-get? governance-proposals proposal-id)
        proposal
        (let
            (
                (current-block block-height)
                (total-votes (+ (+ (get votes-for proposal) (get votes-against proposal)) (get votes-abstain proposal)))
                (approval-rate (calculate-vote-percentage (get votes-for proposal) (+ (get votes-for proposal) (get votes-against proposal))))
            )
            (ok {
                status: (if (get executed proposal) "executed"
                           (if (get cancelled proposal) "cancelled"
                              (if (> current-block (get voting-deadline proposal)) "ended"
                                 "active"))),
                quorum-met: (>= total-votes QUORUM_REQUIREMENT),
                approval-rate: approval-rate,
                can-execute: (and 
                    (> current-block (+ (get voting-deadline proposal) (get execution-delay proposal)))
                    (>= total-votes QUORUM_REQUIREMENT)
                    (>= approval-rate SUPER_MAJORITY_THRESHOLD)
                    (not (get executed proposal))
                    (not (get cancelled proposal))
                )
            })
        )
        ERR-PROPOSAL_NOT_EXIST
    )
)

(define-read-only (get-user-proposals (user principal))
    (default-to (list) (map-get? proposal-creators user))
)

(define-read-only (get-platform-stats)
    {
        total-proposals: (var-get proposal-counter),
        total-voting-power: (var-get total-voting-power),
        platform-paused: (var-get platform-paused),
        treasury-balance: (var-get treasury-balance),
        admin: GOVERNANCE_ADMIN,
        quorum-requirement: QUORUM_REQUIREMENT,
        super-majority-threshold: SUPER_MAJORITY_THRESHOLD
    }
)

(define-read-only (get-active-proposals)
    ;; This would need to be implemented with a filter function in a real deployment
    ;; For now, returns the next proposal ID to check
    (var-get proposal-counter)
)