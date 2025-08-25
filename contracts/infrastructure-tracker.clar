;; ethereum-infrastructure-tracker
;; A smart contract for tracking and managing Ethereum infrastructure resources
;; This contract enables infrastructure admins to register, monitor, and manage
;; distributed infrastructure resources with transparent, blockchain-based tracking.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-QUEST-NOT-FOUND (err u101))
(define-constant ERR-INVALID-FREQUENCY (err u102))
(define-constant ERR-INVALID-DIFFICULTY (err u103))
(define-constant ERR-ALREADY-COMPLETED-TODAY (err u104))
(define-constant ERR-QUEST-NOT-ACTIVE (err u105))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u106))
(define-constant ERR-ALREADY-JOINED-CHALLENGE (err u107))
(define-constant ERR-NOT-CHALLENGE-MEMBER (err u108))
(define-constant ERR-TEMPLATE-NOT-FOUND (err u109))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u110))
(define-constant ERR-TEMPLATE-NOT-FOR-SALE (err u111))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant FREQUENCY-DAILY u1)
(define-constant FREQUENCY-WEEKLY u2)
(define-constant FREQUENCY-MONTHLY u3)
(define-constant FREQUENCY-CUSTOM u4)

(define-constant DIFFICULTY-EASY u1)
(define-constant DIFFICULTY-MEDIUM u2)
(define-constant DIFFICULTY-HARD u3)

;; Data structures

;; Quest data structure
(define-map quests
  { quest-id: uint }
  {
    owner: principal,
    name: (string-ascii 50),
    description: (string-utf8 200),
    frequency: uint,
    custom-interval: (optional uint),
    difficulty: uint,
    rewards: uint,
    active: bool,
    created-at: uint,
    template-id: (optional uint)
  }
)

;; User profile data
(define-map user-profiles
  { user: principal }
  {
    reputation: uint,
    total-quests-completed: uint,
    longest-streak: uint,
    current-streak: uint,
    last-active: uint
  }
)

;; Quest completion records
(define-map quest-completions
  { quest-id: uint, date: uint }
  {
    user: principal,
    verified: bool,
    timestamp: uint
  }
)

;; User quest registry (tracks which quests belong to a user)
(define-map user-quests
  { user: principal }
  { quest-ids: (list 100 uint) }
)

;; Track user's current streak for each quest
(define-map quest-streaks
  { quest-id: uint, user: principal }
  {
    current-streak: uint,
    longest-streak: uint,
    last-completion-date: uint
  }
)

;; Quest templates that can be shared or sold
(define-map quest-templates
  { template-id: uint }
  {
    creator: principal,
    name: (string-ascii 50),
    description: (string-utf8 200),
    frequency: uint,
    custom-interval: (optional uint),
    difficulty: uint,
    recommended-rewards: uint,
    for-sale: bool,
    price: uint,
    purchase-count: uint
  }
)

;; Community challenges
(define-map community-challenges
  { challenge-id: uint }
  {
    creator: principal,
    name: (string-ascii 50),
    description: (string-utf8 200),
    quest-template-id: uint,
    start-date: uint,
    end-date: uint,
    active: bool,
    participants: (list 100 principal)
  }
)

;; Challenge leaderboard
(define-map challenge-leaderboards
  { challenge-id: uint }
  {
    user-scores: (list 100 { user: principal, score: uint, streak: uint })
  }
)

;; Counters
(define-data-var quest-id-counter uint u0)
(define-data-var template-id-counter uint u0)
(define-data-var challenge-id-counter uint u0)

;; Private functions

;; Increment and return the next quest ID
(define-private (get-next-quest-id)
  (let ((next-id (+ (var-get quest-id-counter) u1)))
    (var-set quest-id-counter next-id)
    next-id
  )
)

;; Increment and return the next template ID
(define-private (get-next-template-id)
  (let ((next-id (+ (var-get template-id-counter) u1)))
    (var-set template-id-counter next-id)
    next-id
  )
)

;; Increment and return the next challenge ID
(define-private (get-next-challenge-id)
  (let ((next-id (+ (var-get challenge-id-counter) u1)))
    (var-set challenge-id-counter next-id)
    next-id
  )
)

;; Add a quest ID to a user's quest list
(define-private (add-quest-to-user-list (user principal) (quest-id uint))
  (let ((current-quests (default-to { quest-ids: (list) } (map-get? user-quests { user: user }))))
    (map-set user-quests
      { user: user }
      { quest-ids: (unwrap-panic (as-max-len? (append (get quest-ids current-quests) quest-id) u100)) }
    )
  )
)

;; Initialize or update user profile
(define-private (init-or-update-user-profile (user principal))
  (let ((existing-profile (map-get? user-profiles { user: user })))
    (if (is-some existing-profile)
      true
      (map-set user-profiles
        { user: user }
        {
          reputation: u0,
          total-quests-completed: u0,
          longest-streak: u0,
          current-streak: u0,
          last-active: (unwrap-panic (get-block-info? time u0))
        }
      )
    )
  )
)

;; Update user profile with new streak information
(define-private (update-user-profile-streak (user principal) (current-quest-streak uint))
  (let (
    (profile (default-to 
      { reputation: u0, total-quests-completed: u0, longest-streak: u0, current-streak: u0, last-active: u0 }
      (map-get? user-profiles { user: user })
    ))
    (new-longest-streak (if (> current-quest-streak (get longest-streak profile))
                           current-quest-streak
                           (get longest-streak profile)))
  )
    (map-set user-profiles
      { user: user }
      {
        reputation: (get reputation profile),
        total-quests-completed: (get total-quests-completed profile),
        longest-streak: new-longest-streak,
        current-streak: (+ (get current-streak profile) u1),
        last-active: (unwrap-panic (get-block-info? time u0))
      }
    )
  )
)

;; Update user streak for a quest
(define-private (update-quest-streak (quest-id uint) (user principal))
  (let (
    (current-time (unwrap-panic (get-block-info? time u0)))
    (current-date (/ current-time (* u60 u60 u24))) ;; Convert to days
    (streak-info (default-to 
      { current-streak: u0, longest-streak: u0, last-completion-date: u0 }
      (map-get? quest-streaks { quest-id: quest-id, user: user })
    ))
    (quest-data (unwrap! (map-get? quests { quest-id: quest-id }) false))
    (last-completion-date (get last-completion-date streak-info))
    (expected-interval (if (is-eq (get frequency quest-data) FREQUENCY-DAILY)
                          u1
                          (if (is-eq (get frequency quest-data) FREQUENCY-WEEKLY)
                            u7
                            (if (is-eq (get frequency quest-data) FREQUENCY-MONTHLY)
                              u30
                              (default-to u1 (get custom-interval quest-data))
                            )
                          )))
    (streak-maintained (or 
                        (is-eq last-completion-date u0)  ;; First completion
                        (and 
                          (> current-date last-completion-date)
                          (<= (- current-date last-completion-date) expected-interval)
                        )))
    (new-current-streak (if streak-maintained (+ (get current-streak streak-info) u1) u1))
    (new-longest-streak (if (> new-current-streak (get longest-streak streak-info))
                          new-current-streak
                          (get longest-streak streak-info)))
  )
    (map-set quest-streaks
      { quest-id: quest-id, user: user }
      {
        current-streak: new-current-streak,
        longest-streak: new-longest-streak,
        last-completion-date: current-date
      }
    )
    (update-user-profile-streak user new-current-streak)
    true
  )
)

;; Validate frequency value
(define-private (is-valid-frequency (frequency uint))
  (or
    (is-eq frequency FREQUENCY-DAILY)
    (is-eq frequency FREQUENCY-WEEKLY)
    (is-eq frequency FREQUENCY-MONTHLY)
    (is-eq frequency FREQUENCY-CUSTOM)
  )
)

;; Validate difficulty value
(define-private (is-valid-difficulty (difficulty uint))
  (or
    (is-eq difficulty DIFFICULTY-EASY)
    (is-eq difficulty DIFFICULTY-MEDIUM)
    (is-eq difficulty DIFFICULTY-HARD)
  )
)

;; Helper to find user index in leaderboard entries
(define-private (find-user-index (entries (list 100 { user: principal, score: uint, streak: uint })) (target-user principal) (current-index uint))
  (get result
    (fold find-user-index-fold 
      entries
      {
        target-user: target-user,
        current-index: u0,
        found-index: none,
        result: none
      }
    )
  )
)

;; Helper for find-user-index using fold
(define-private (find-user-index-fold 
  (entry { user: principal, score: uint, streak: uint }) 
  (state { target-user: principal, current-index: uint, found-index: (optional uint), result: (optional uint) })
)
  (if (is-some (get result state))
    ;; Already found, just return
    state
    (if (is-eq (get user entry) (get target-user state))
      ;; Found match, record it
      (merge state { 
        found-index: (some (get current-index state)),
        result: (some (get current-index state))
      })
      ;; No match, increment index and continue
      (merge state { current-index: (+ (get current-index state) u1) })
    )
  )
)

;; Helper function to update an entry at a specific index using fold
(define-private (update-entry-at-index 
  (entry { user: principal, score: uint, streak: uint })
  (state { 
    entries: (list 100 { user: principal, score: uint, streak: uint }),
    target-index: uint,
    current-index: uint,
    new-entry: { user: principal, score: uint, streak: uint }
  })
)
  (let (
    (is-target (is-eq (get current-index state) (get target-index state)))
    (current-entries (get entries state))
    (updated-entry (if is-target
                     (merge entry {
                       score: (+ (get score entry) (get score (get new-entry state))),
                       streak: (get streak (get new-entry state))
                     })
                     entry))
  )
    (merge state {
      entries: (unwrap-panic (as-max-len? (append current-entries updated-entry) u100)),
      current-index: (+ (get current-index state) u1)
    })
  )
)

;; Update or add user entry in the leaderboard list
(define-private (update-leaderboard-entry (entries (list 100 { user: principal, score: uint, streak: uint })) (new-entry { user: principal, score: uint, streak: uint }))
  (let (
    (user-index (find-user-index entries (get user new-entry) u0))
  )
    (if (is-some user-index)
      ;; Update existing entry by creating a new list with the updated entry
      (get entries (fold update-entry-at-index 
        entries
        { 
          entries: (list), 
          target-index: (unwrap-panic user-index),
          current-index: u0,
          new-entry: new-entry
        }))
      ;; Add new entry if not found
      (unwrap-panic (as-max-len? (append entries new-entry) u100))
    )
  )
)

;; Update challenge leaderboard after quest completion
(define-private (update-challenge-leaderboard (challenge-id uint) (user principal))
  (let (
    (challenge (unwrap! (map-get? community-challenges { challenge-id: challenge-id }) false))
    (is-participant (contains-principal (get participants challenge) user))
    (current-leaderboard (default-to { user-scores: (list) } (map-get? challenge-leaderboards { challenge-id: challenge-id })))
    (user-streak-info (default-to 
                        { current-streak: u0, longest-streak: u0, last-completion-date: u0 }
                        (map-get? quest-streaks { quest-id: (get quest-template-id challenge), user: user })))
    (user-entry { user: user, score: u1, streak: (get current-streak user-streak-info) })
  )
    (if is-participant
      (map-set challenge-leaderboards
        { challenge-id: challenge-id }
        { user-scores: (update-leaderboard-entry (get user-scores current-leaderboard) user-entry) }
      )
      false
    )
  )
)

;; Read-only functions

;; Get user quest list
(define-read-only (get-user-quests (user principal))
  (default-to { quest-ids: (list) } (map-get? user-quests { user: user }))
)

;; Get quest details
(define-read-only (get-quest (quest-id uint))
  (map-get? quests { quest-id: quest-id })
)

;; Get user profile
(define-read-only (get-user-profile (user principal))
  (default-to 
    { reputation: u0, total-quests-completed: u0, longest-streak: u0, current-streak: u0, last-active: u0 }
    (map-get? user-profiles { user: user })
  )
)

;; Check if a quest is completed for a specific date
(define-read-only (is-quest-completed (quest-id uint) (date uint))
  (is-some (map-get? quest-completions { quest-id: quest-id, date: date }))
)

;; Get quest streak information
(define-read-only (get-quest-streak-info (quest-id uint) (user principal))
  (default-to 
    { current-streak: u0, longest-streak: u0, last-completion-date: u0 }
    (map-get? quest-streaks { quest-id: quest-id, user: user })
  )
)

;; Get quest template details
(define-read-only (get-quest-template (template-id uint))
  (map-get? quest-templates { template-id: template-id })
)

;; Get community challenge details
(define-read-only (get-community-challenge (challenge-id uint))
  (map-get? community-challenges { challenge-id: challenge-id })
)

;; Get challenge leaderboard
(define-read-only (get-challenge-leaderboard (challenge-id uint))
  (default-to { user-scores: (list) } (map-get? challenge-leaderboards { challenge-id: challenge-id }))
)

;; Check if user is participant in challenge
(define-read-only (is-challenge-participant (challenge-id uint) (user principal))
  (let ((challenge (unwrap! (map-get? community-challenges { challenge-id: challenge-id }) false)))
    (contains-principal (get participants challenge) user)
  )
)

;; Helper function to check if a list of principals contains a specific principal
(define-private (contains-principal (principals (list 100 principal)) (target principal))
  (is-some (get result
    (fold check-principal-fold 
      principals
      { 
        found: false, 
        target: target,
        result: none
      })
  ))
)

;; Helper for contains-principal
(define-private (check-principal-fold 
  (current-principal principal) 
  (state { found: bool, target: principal, result: (optional bool) })
)
  (if (get found state)
    ;; Already found, just return state
    state
    (if (is-eq current-principal (get target state))
      ;; Found match
      (merge state { found: true, result: (some true) })
      ;; No match, continue checking
      state
    )
  )
)

;; Public functions

;; Create a new quest
(define-public (create-quest 
  (name (string-ascii 50)) 
  (description (string-utf8 200)) 
  (frequency uint) 
  (custom-interval (optional uint)) 
  (difficulty uint) 
  (rewards uint)
  (template-id (optional uint))
)
  (let (
    (new-quest-id (get-next-quest-id))
    (current-time (unwrap-panic (get-block-info? time u0)))
  )
    ;; Validate inputs
    (asserts! (is-valid-frequency frequency) ERR-INVALID-FREQUENCY)
    (asserts! (is-valid-difficulty difficulty) ERR-INVALID-DIFFICULTY)
    
    ;; Initialize user profile if needed
    (init-or-update-user-profile tx-sender)
    
    ;; Create the quest
    (map-set quests
      { quest-id: new-quest-id }
      {
        owner: tx-sender,
        name: name,
        description: description,
        frequency: frequency,
        custom-interval: custom-interval,
        difficulty: difficulty,
        rewards: rewards,
        active: true,
        created-at: current-time,
        template-id: template-id
      }
    )
    
    ;; Add quest to user's list
    (add-quest-to-user-list tx-sender new-quest-id)
    
    (ok new-quest-id)
  )
)

;; Create a quest from an existing template
(define-public (create-quest-from-template (template-id uint))
  (let (
    (template (unwrap! (map-get? quest-templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
  )
    (create-quest
      (get name template)
      (get description template)
      (get frequency template)
      (get custom-interval template)
      (get difficulty template)
      (get recommended-rewards template)
      (some template-id)
    )
  )
)

;; Log completion of a quest
(define-public (complete-quest (quest-id uint))
  (let (
    (quest (unwrap! (map-get? quests { quest-id: quest-id }) ERR-QUEST-NOT-FOUND))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (current-date (/ current-time (* u60 u60 u24))) ;; Convert to days
  )
    ;; Verify user owns the quest or is part of the challenge
    (asserts! (or (is-eq tx-sender (get owner quest)) 
                 (let ((template-id (get template-id quest)))
                   (and (is-some template-id)
                        (is-challenge-participant (unwrap-panic template-id) tx-sender))))
             ERR-NOT-AUTHORIZED)
    
    ;; Verify quest is active
    (asserts! (get active quest) ERR-QUEST-NOT-ACTIVE)
    
    ;; Verify not already completed today
    (asserts! (not (is-quest-completed quest-id current-date)) ERR-ALREADY-COMPLETED-TODAY)
    
    ;; Record completion
    (map-set quest-completions
      { quest-id: quest-id, date: current-date }
      {
        user: tx-sender,
        verified: true,
        timestamp: current-time
      }
    )
    
    ;; Update user streaks
    (update-quest-streak quest-id tx-sender)
    
    ;; Update user profile and reputation
    (let (
      (profile (default-to 
        { reputation: u0, total-quests-completed: u0, longest-streak: u0, current-streak: u0, last-active: u0 }
        (map-get? user-profiles { user: tx-sender })
      ))
      (reward-points (* (get difficulty quest) u10))
    )
      (map-set user-profiles
        { user: tx-sender }
        {
          reputation: (+ (get reputation profile) reward-points),
          total-quests-completed: (+ (get total-quests-completed profile) u1),
          longest-streak: (get longest-streak profile),
          current-streak: (get current-streak profile),
          last-active: current-time
        }
      )
    )
    
    ;; Update challenge leaderboard if applicable
    (if (is-some (get template-id quest))
      (update-challenge-leaderboard (unwrap-panic (get template-id quest)) tx-sender)
      true
    )
    
    (ok true)
  )
)

;; Create a quest template that can be shared or sold
(define-public (create-quest-template 
  (name (string-ascii 50)) 
  (description (string-utf8 200)) 
  (frequency uint) 
  (custom-interval (optional uint)) 
  (difficulty uint) 
  (recommended-rewards uint)
  (for-sale bool)
  (price uint)
)
  (let (
    (new-template-id (get-next-template-id))
  )
    ;; Validate inputs
    (asserts! (is-valid-frequency frequency) ERR-INVALID-FREQUENCY)
    (asserts! (is-valid-difficulty difficulty) ERR-INVALID-DIFFICULTY)
    
    ;; Create the template
    (map-set quest-templates
      { template-id: new-template-id }
      {
        creator: tx-sender,
        name: name,
        description: description,
        frequency: frequency,
        custom-interval: custom-interval,
        difficulty: difficulty,
        recommended-rewards: recommended-rewards,
        for-sale: for-sale,
        price: price,
        purchase-count: u0
      }
    )
    
    (ok new-template-id)
  )
)

;; Purchase a quest template
(define-public (purchase-template (template-id uint))
  (let (
    (template (unwrap! (map-get? quest-templates { template-id: template-id }) ERR-TEMPLATE-NOT-FOUND))
    (user-profile (default-to 
      { reputation: u0, total-quests-completed: u0, longest-streak: u0, current-streak: u0, last-active: u0 }
      (map-get? user-profiles { user: tx-sender })
    ))
  )
    ;; Check if template is for sale
    (asserts! (get for-sale template) ERR-TEMPLATE-NOT-FOR-SALE)
    
    ;; Check if user has enough reputation to purchase
    (asserts! (>= (get reputation user-profile) (get price template)) ERR-INSUFFICIENT-REPUTATION)
    
    ;; Deduct reputation from buyer
    (map-set user-profiles
      { user: tx-sender }
      {
        reputation: (- (get reputation user-profile) (get price template)),
        total-quests-completed: (get total-quests-completed user-profile),
        longest-streak: (get longest-streak user-profile),
        current-streak: (get current-streak user-profile),
        last-active: (get last-active user-profile)
      }
    )
    
    ;; Add reputation to creator
    (let (
      (creator-profile (default-to 
        { reputation: u0, total-quests-completed: u0, longest-streak: u0, current-streak: u0, last-active: u0 }
        (map-get? user-profiles { user: (get creator template) })
      ))
    )
      (map-set user-profiles
        { user: (get creator template) }
        {
          reputation: (+ (get reputation creator-profile) (get price template)),
          total-quests-completed: (get total-quests-completed creator-profile),
          longest-streak: (get longest-streak creator-profile),
          current-streak: (get current-streak creator-profile),
          last-active: (get last-active creator-profile)
        }
      )
    )
    
    ;; Update purchase count
    (map-set quest-templates
      { template-id: template-id }
      {
        creator: (get creator template),
        name: (get name template),
        description: (get description template),
        frequency: (get frequency template),
        custom-interval: (get custom-interval template),
        difficulty: (get difficulty template),
        recommended-rewards: (get recommended-rewards template),
        for-sale: (get for-sale template),
        price: (get price template),
        purchase-count: (+ (get purchase-count template) u1)
      }
    )
    
    ;; Create a quest for the buyer from the template
    (create-quest-from-template template-id)
  )
)

;; Create a community challenge
(define-public (create-community-challenge
  (name (string-ascii 50))
  (description (string-utf8 200))
  (quest-template-id uint)
  (start-date uint)
  (end-date uint)
)
  (let (
    (new-challenge-id (get-next-challenge-id))
    (template (unwrap! (map-get? quest-templates { template-id: quest-template-id }) ERR-TEMPLATE-NOT-FOUND))
    (current-time (unwrap-panic (get-block-info? time u0)))
  )
    ;; Validate dates
    (asserts! (> end-date start-date) (err u112))
    (asserts! (>= start-date (/ current-time (* u60 u60 u24))) (err u113))
    
    ;; Create the challenge
    (map-set community-challenges
      { challenge-id: new-challenge-id }
      {
        creator: tx-sender,
        name: name,
        description: description,
        quest-template-id: quest-template-id,
        start-date: start-date,
        end-date: end-date,
        active: true,
        participants: (list tx-sender)
      }
    )
    
    ;; Initialize leaderboard
    (map-set challenge-leaderboards
      { challenge-id: new-challenge-id }
      { user-scores: (list { user: tx-sender, score: u0, streak: u0 }) }
    )
    
    ;; Creator automatically joins their own challenge
    ;; We're not checking the response but it should succeed since we already verified the template exists
    (try! (create-quest-from-template quest-template-id))
    
    (ok new-challenge-id)
  )
)

;; Join a community challenge
(define-public (join-challenge (challenge-id uint))
  (let (
    (challenge (unwrap! (map-get? community-challenges { challenge-id: challenge-id }) ERR-CHALLENGE-NOT-FOUND))
    (is-participant (contains-principal (get participants challenge) tx-sender))
    (current-time (unwrap-panic (get-block-info? time u0)))
    (current-date (/ current-time (* u60 u60 u24)))
  )
    ;; Verify challenge is active and not expired
    (asserts! (get active challenge) ERR-QUEST-NOT-ACTIVE)
    (asserts! (<= current-date (get end-date challenge)) ERR-QUEST-NOT-ACTIVE)
    
    ;; Verify user is not already in the challenge
    (asserts! (not is-participant) ERR-ALREADY-JOINED-CHALLENGE)
    
    ;; Add user to participants
    (map-set community-challenges
      { challenge-id: challenge-id }
      {
        creator: (get creator challenge),
        name: (get name challenge),
        description: (get description challenge),
        quest-template-id: (get quest-template-id challenge),
        start-date: (get start-date challenge),
        end-date: (get end-date challenge),
        active: (get active challenge),
        participants: (unwrap-panic (as-max-len? (append (get participants challenge) tx-sender) u100))
      }
    )
    
    ;; Add user to leaderboard
    (let (
      (leaderboard (default-to { user-scores: (list) } (map-get? challenge-leaderboards { challenge-id: challenge-id })))
    )
      (map-set challenge-leaderboards
        { challenge-id: challenge-id }
        { user-scores: (unwrap-panic (as-max-len? (append (get user-scores leaderboard) { user: tx-sender, score: u0, streak: u0 }) u100)) }
      )
    )
    
    ;; Create the quest for the user from the template
    (create-quest-from-template (get quest-template-id challenge))
  )
)

;; Toggle quest active status
(define-public (toggle-quest-active (quest-id uint))
  (let (
    (quest (unwrap! (map-get? quests { quest-id: quest-id }) ERR-QUEST-NOT-FOUND))
  )
    ;; Verify ownership
    (asserts! (is-eq tx-sender (get owner quest)) ERR-NOT-AUTHORIZED)
    
    ;; Toggle active status
    (map-set quests
      { quest-id: quest-id }
      {
        owner: (get owner quest),
        name: (get name quest),
        description: (get description quest),
        frequency: (get frequency quest),
        custom-interval: (get custom-interval quest),
        difficulty: (get difficulty quest),
        rewards: (get rewards quest),
        active: (not (get active quest)),
        created-at: (get created-at quest),
        template-id: (get template-id quest)
      }
    )
    
    (ok (not (get active quest)))
  )
)