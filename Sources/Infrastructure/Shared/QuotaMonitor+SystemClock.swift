import Domain

public extension QuotaMonitor {
    convenience init(
        providers: any AIProviderRepository,
        alerter: (any QuotaAlerter)? = nil,
        powerStateProvider: (any PowerStateProvider)? = SystemPowerStateProvider(),
        providerFactory: ProviderFactory? = nil
    ) {
        self.init(
            providers: providers,
            alerter: alerter,
            clock: SystemClock(),
            powerStateProvider: powerStateProvider,
            providerFactory: providerFactory
        )
    }
}
