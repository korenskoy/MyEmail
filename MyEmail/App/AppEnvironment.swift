//
//  AppEnvironment.swift
//  MyEmail
//
//  Service container — единственное место, где сервисы создаются и держатся
//  на всём lifecycle приложения. Инжектится в Views через `.environment(...)`
//  из `MyEmailApp`.
//
//  В M1 — минимальный набор (LogService, KeychainService, DatabaseService).
//  В M2+ добавятся AuthService, IMAPService actors, SyncService, SMTPService,
//  ContactsService, NotificationService, RuleEngine.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    // Lifecycle tokens
    private var appNapActivity: NSObjectProtocol?

    // M1 core services
    let logService: LogService
    let keychain: KeychainService
    let database: DatabaseService

    // M2 account management
    let accountRepository: AccountRepository
    let authService: AuthService

    // M3 sync + M6 offline queue
    let syncService: SyncService
    let offlineQueue: OfflineQueueService

    // Undo (§7.3)
    let undoService: UndoActionService

    // Draft crash recovery (§5.2)
    let draftRecovery: DraftRecoveryService

    // Gravatar (§4.5)
    let gravatarService: GravatarService

    // Rules (§6.7.1)
    let ruleEngine: RuleEngine

    // Trusted senders
    let trustedSenderService: TrustedSenderService

    init() {
        self.logService = LogService.shared
        self.keychain = KeychainService.shared
        self.database = DatabaseService.shared

        self.accountRepository = AccountRepository()
        self.authService = AuthService(
            accountRepository: accountRepository,
            keychain: keychain
        )

        let rules = RuleEngine()
        self.ruleEngine = rules

        let queue = OfflineQueueService()
        self.offlineQueue = queue
        let sync = SyncService()
        sync.offlineQueue = queue
        sync.authService = authService
        sync.ruleEngine = rules
        self.syncService = sync
        self.undoService = UndoActionService(syncService: sync)
        self.draftRecovery = DraftRecoveryService()
        self.gravatarService = GravatarService()
        self.trustedSenderService = TrustedSenderService()

        // Start network monitor + App Nap prevention + proactive OAuth sweep
        sync.startNetworkMonitor()
        self.appNapActivity = sync.beginAppNapPrevention()
        sync.startPeriodicSync()
        sync.startWakeObserver()
        Task { await authService.startProactiveSweep() }

        // Notifications
        let notifications = NotificationService.shared
        notifications.setupDelegate()
        Task { await notifications.requestAuthorization() }

        LogService.log(.info, .uiDebug, "App started")
    }
}
