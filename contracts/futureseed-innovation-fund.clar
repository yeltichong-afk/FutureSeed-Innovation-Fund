(define-constant ERR_UNAUTHORIZED u401)
(define-constant ERR_PROPOSAL_NOT_FOUND u402)
(define-constant ERR_INSUFFICIENT_FUNDS u403)
(define-constant ERR_VOTING_ENDED u404)
(define-constant ERR_ALREADY_VOTED u405)
(define-constant ERR_PROPOSAL_NOT_ACTIVE u406)
(define-constant ERR_INVALID_AMOUNT u407)
(define-constant ERR_MILESTONE_NOT_FOUND u408)
(define-constant ERR_ALREADY_FUNDED u409)
(define-constant ERR_VOTING_NOT_ENDED u410)

(define-constant PROPOSAL_STATUS_PENDING u0)
(define-constant PROPOSAL_STATUS_ACTIVE u1)
(define-constant PROPOSAL_STATUS_FUNDED u2)
(define-constant PROPOSAL_STATUS_COMPLETED u3)
(define-constant PROPOSAL_STATUS_REJECTED u4)

(define-constant MILESTONE_STATUS_PENDING u0)
(define-constant MILESTONE_STATUS_COMPLETED u1)
(define-constant MILESTONE_STATUS_APPROVED u2)

(define-constant VOTING_PERIOD u1440)
(define-constant MIN_FUNDING_AMOUNT u1000000)
(define-constant FUND_FEE_PERCENTAGE u5)

(define-data-var proposal-counter uint u0)
(define-data-var milestone-counter uint u0)
(define-data-var total-fund-balance uint u0)
(define-data-var contract-owner principal tx-sender)

(define-map proposals uint {
    creator: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    funding-goal: uint,
    current-funding: uint,
    voting-ends: uint,
    yes-votes: uint,
    no-votes: uint,
    status: uint,
    created-at: uint,
    funded-at: (optional uint)
})

(define-map proposal-votes { proposal-id: uint, voter: principal } {
    vote: bool,
    amount: uint
})

(define-map user-stakes principal uint)

(define-map milestones uint {
    proposal-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 300),
    funding-amount: uint,
    status: uint,
    created-at: uint,
    completed-at: (optional uint)
})

(define-map proposal-milestones uint (list 10 uint))

(define-map user-profiles principal {
    total-staked: uint,
    proposals-created: uint,
    votes-cast: uint,
    reputation: uint,
    total-earned: uint
})

(define-public (create-proposal (title (string-ascii 100)) (description (string-ascii 500)) (funding-goal uint))
    (let (
        (proposal-id (+ (var-get proposal-counter) u1))
        (voting-deadline (+ burn-block-height VOTING_PERIOD))
    )
        (asserts! (>= funding-goal MIN_FUNDING_AMOUNT) (err ERR_INVALID_AMOUNT))
        (map-set proposals proposal-id {
            creator: tx-sender,
            title: title,
            description: description,
            funding-goal: funding-goal,
            current-funding: u0,
            voting-ends: voting-deadline,
            yes-votes: u0,
            no-votes: u0,
            status: PROPOSAL_STATUS_PENDING,
            created-at: burn-block-height,
            funded-at: none
        })
        (var-set proposal-counter proposal-id)
        (update-user-profile-proposals tx-sender)
        (ok proposal-id)
    )
)

(define-public (vote-on-proposal (proposal-id uint) (vote bool) (stake-amount uint))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) (err ERR_PROPOSAL_NOT_FOUND)))
        (current-stake (default-to u0 (map-get? user-stakes tx-sender)))
    )
        (asserts! (< burn-block-height (get voting-ends proposal)) (err ERR_VOTING_ENDED))
        (asserts! (is-eq (get status proposal) PROPOSAL_STATUS_PENDING) (err ERR_PROPOSAL_NOT_ACTIVE))
        (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })) (err ERR_ALREADY_VOTED))
        (asserts! (> stake-amount u0) (err ERR_INVALID_AMOUNT))
        
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
        (map-set user-stakes tx-sender (+ current-stake stake-amount))
        (map-set proposal-votes { proposal-id: proposal-id, voter: tx-sender } { vote: vote, amount: stake-amount })
        
        (if vote
            (map-set proposals proposal-id (merge proposal { yes-votes: (+ (get yes-votes proposal) stake-amount) }))
            (map-set proposals proposal-id (merge proposal { no-votes: (+ (get no-votes proposal) stake-amount) }))
        )
        
        (update-user-profile-votes tx-sender)
        (ok true)
    )
)

(define-public (finalize-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) (err ERR_PROPOSAL_NOT_FOUND)))
    )
        (asserts! (>= burn-block-height (get voting-ends proposal)) (err ERR_VOTING_NOT_ENDED))
        (asserts! (is-eq (get status proposal) PROPOSAL_STATUS_PENDING) (err ERR_PROPOSAL_NOT_ACTIVE))
        
        (if (> (get yes-votes proposal) (get no-votes proposal))
            (map-set proposals proposal-id (merge proposal { status: PROPOSAL_STATUS_ACTIVE }))
            (map-set proposals proposal-id (merge proposal { status: PROPOSAL_STATUS_REJECTED }))
        )
        (ok true)
    )
)

(define-public (fund-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) (err ERR_PROPOSAL_NOT_FOUND)))
        (funding-amount (get funding-goal proposal))
        (fee-amount (/ (* funding-amount FUND_FEE_PERCENTAGE) u100))
        (net-amount (- funding-amount fee-amount))
    )
        (asserts! (is-eq (get status proposal) PROPOSAL_STATUS_ACTIVE) (err ERR_PROPOSAL_NOT_ACTIVE))
        (asserts! (>= (var-get total-fund-balance) funding-amount) (err ERR_INSUFFICIENT_FUNDS))
        
        (try! (as-contract (stx-transfer? net-amount tx-sender (get creator proposal))))
        (try! (as-contract (stx-transfer? fee-amount tx-sender (var-get contract-owner))))
        
        (var-set total-fund-balance (- (var-get total-fund-balance) funding-amount))
        (map-set proposals proposal-id (merge proposal { 
            status: PROPOSAL_STATUS_FUNDED,
            current-funding: funding-amount,
            funded-at: (some burn-block-height)
        }))
        (update-user-profile-earnings (get creator proposal) net-amount)
        (ok true)
    )
)

(define-public (add-milestone (proposal-id uint) (title (string-ascii 100)) (description (string-ascii 300)) (funding-amount uint))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) (err ERR_PROPOSAL_NOT_FOUND)))
        (milestone-id (+ (var-get milestone-counter) u1))
        (current-milestones (default-to (list) (map-get? proposal-milestones proposal-id)))
    )
        (asserts! (is-eq tx-sender (get creator proposal)) (err ERR_UNAUTHORIZED))
        (asserts! (> funding-amount u0) (err ERR_INVALID_AMOUNT))
        
        (map-set milestones milestone-id {
            proposal-id: proposal-id,
            title: title,
            description: description,
            funding-amount: funding-amount,
            status: MILESTONE_STATUS_PENDING,
            created-at: burn-block-height,
            completed-at: none
        })
        (map-set proposal-milestones proposal-id (unwrap! (as-max-len? (append current-milestones milestone-id) u10) (err ERR_INVALID_AMOUNT)))
        (var-set milestone-counter milestone-id)
        (ok milestone-id)
    )
)

(define-public (complete-milestone (milestone-id uint))
    (let (
        (milestone (unwrap! (map-get? milestones milestone-id) (err ERR_MILESTONE_NOT_FOUND)))
        (proposal (unwrap! (map-get? proposals (get proposal-id milestone)) (err ERR_PROPOSAL_NOT_FOUND)))
    )
        (asserts! (is-eq tx-sender (get creator proposal)) (err ERR_UNAUTHORIZED))
        (asserts! (is-eq (get status milestone) MILESTONE_STATUS_PENDING) (err ERR_PROPOSAL_NOT_ACTIVE))
        
        (map-set milestones milestone-id (merge milestone {
            status: MILESTONE_STATUS_COMPLETED,
            completed-at: (some burn-block-height)
        }))
        (ok true)
    )
)

(define-public (approve-milestone (milestone-id uint))
    (let (
        (milestone (unwrap! (map-get? milestones milestone-id) (err ERR_MILESTONE_NOT_FOUND)))
        (funding-amount (get funding-amount milestone))
        (proposal (unwrap! (map-get? proposals (get proposal-id milestone)) (err ERR_PROPOSAL_NOT_FOUND)))
    )
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
        (asserts! (is-eq (get status milestone) MILESTONE_STATUS_COMPLETED) (err ERR_PROPOSAL_NOT_ACTIVE))
        (asserts! (>= (var-get total-fund-balance) funding-amount) (err ERR_INSUFFICIENT_FUNDS))
        
        (try! (as-contract (stx-transfer? funding-amount tx-sender (get creator proposal))))
        (var-set total-fund-balance (- (var-get total-fund-balance) funding-amount))
        (map-set milestones milestone-id (merge milestone { status: MILESTONE_STATUS_APPROVED }))
        (update-user-profile-earnings (get creator proposal) funding-amount)
        (ok true)
    )
)

(define-public (contribute-to-fund)
    (let (
        (amount (stx-get-balance tx-sender))
    )
        (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set total-fund-balance (+ (var-get total-fund-balance) amount))
        (update-user-profile-stake tx-sender amount)
        (ok true)
    )
)

(define-public (withdraw-stake (amount uint))
    (let (
        (current-stake (default-to u0 (map-get? user-stakes tx-sender)))
    )
        (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
        (asserts! (>= current-stake amount) (err ERR_INSUFFICIENT_FUNDS))
        
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (map-set user-stakes tx-sender (- current-stake amount))
        (ok true)
    )
)

(define-private (update-user-profile-proposals (user principal))
    (let (
        (current-profile (default-to { total-staked: u0, proposals-created: u0, votes-cast: u0, reputation: u0, total-earned: u0 } 
                         (map-get? user-profiles user)))
    )
        (map-set user-profiles user (merge current-profile { 
            proposals-created: (+ (get proposals-created current-profile) u1),
            reputation: (+ (get reputation current-profile) u10)
        }))
        true
    )
)

(define-private (update-user-profile-votes (user principal))
    (let (
        (current-profile (default-to { total-staked: u0, proposals-created: u0, votes-cast: u0, reputation: u0, total-earned: u0 } 
                         (map-get? user-profiles user)))
    )
        (map-set user-profiles user (merge current-profile { 
            votes-cast: (+ (get votes-cast current-profile) u1),
            reputation: (+ (get reputation current-profile) u5)
        }))
        true
    )
)

(define-private (update-user-profile-stake (user principal) (amount uint))
    (let (
        (current-profile (default-to { total-staked: u0, proposals-created: u0, votes-cast: u0, reputation: u0, total-earned: u0 } 
                         (map-get? user-profiles user)))
    )
        (map-set user-profiles user (merge current-profile { 
            total-staked: (+ (get total-staked current-profile) amount),
            reputation: (+ (get reputation current-profile) u2)
        }))
        true
    )
)

(define-private (update-user-profile-earnings (user principal) (amount uint))
    (let (
        (current-profile (default-to { total-staked: u0, proposals-created: u0, votes-cast: u0, reputation: u0, total-earned: u0 } 
                         (map-get? user-profiles user)))
    )
        (map-set user-profiles user (merge current-profile { 
            total-earned: (+ (get total-earned current-profile) amount),
            reputation: (+ (get reputation current-profile) u20)
        }))
        true
    )
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-milestone (milestone-id uint))
    (map-get? milestones milestone-id)
)

(define-read-only (get-user-stake (user principal))
    (default-to u0 (map-get? user-stakes user))
)

(define-read-only (get-user-profile (user principal))
    (map-get? user-profiles user)
)

(define-read-only (get-proposal-vote (proposal-id uint) (voter principal))
    (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-proposal-milestones (proposal-id uint))
    (map-get? proposal-milestones proposal-id)
)

(define-read-only (get-fund-balance)
    (var-get total-fund-balance)
)

(define-read-only (get-proposal-stats (proposal-id uint))
    (match (map-get? proposals proposal-id)
        proposal (some {
            total-votes: (+ (get yes-votes proposal) (get no-votes proposal)),
            approval-rate: (if (> (+ (get yes-votes proposal) (get no-votes proposal)) u0)
                              (/ (* (get yes-votes proposal) u100) (+ (get yes-votes proposal) (get no-votes proposal)))
                              u0),
            days-remaining: (if (> (get voting-ends proposal) burn-block-height)
                               (/ (- (get voting-ends proposal) burn-block-height) u144)
                               u0)
        })
        none
    )
)

(define-read-only (get-contract-stats)
    {
        total-proposals: (var-get proposal-counter),
        total-milestones: (var-get milestone-counter),
        fund-balance: (var-get total-fund-balance),
        contract-owner: (var-get contract-owner)
    }
)