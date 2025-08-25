import SwiftUI
import UserNotifications
import CoreLocation
import AuthenticationServices

extension Color {
    static let primaryGradient = LinearGradient(
        colors: [.purple, .blue, .pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardBackground = LinearGradient(
        colors: [.orange.opacity(0.6), .pink.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Models

enum Genre: String, CaseIterable, Codable, Identifiable {
    case strategy = "Strategy"
    case family = "Family"
    case party = "Party"
    case cooperative = "Cooperative"
    case abstract = "Abstract"
    case thematic = "Thematic"
    
    var id: String { rawValue }
}

enum Difficulty: String, CaseIterable, Codable, Identifiable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"
    
    var id: String { rawValue }
}

struct BoardGame: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var genre: Genre
    var minPlayers: Int
    var maxPlayers: Int
    var minAge: Int
    var difficulty: Difficulty
    var dailyPrice: Double
    var deposit: Double
    var imageName: String
    var description: String
    var rating: Double
    
    var playersText: String { "\(minPlayers)-\(maxPlayers) players" }
    var ageText: String { "Ages \(minAge)+" }
}

enum RentalStatus: String, Codable { case booked, pickedUp, returned }
enum PaymentStatus: String, Codable { case unpaid, paid, refunded }

struct Rental: Identifiable, Codable, Hashable {
    let id: UUID
    var game: BoardGame
    var pickup: Date
    var returnDate: Date
    var days: Int
    var dailyPrice: Double
    var deposit: Double
    var totalPaid: Double
    var status: RentalStatus
    var paymentStatus: PaymentStatus
}

struct RentalState: Codable {
    var active: [Rental] = []
    var past: [Rental] = []
}

struct UserProfile: Codable {
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var location: String = "" // e.g., "Orlando, FL, USA"
}

// MARK: - Onboarding

enum AppStage: String, Codable { case auth, location, main }

// MARK: - Persistence

final class Persistence {
    static let shared = Persistence()
    private let defaults = UserDefaults.standard
    private let stateKey = "rental_state_v1"
    private let profileKey = "user_profile_v1"
    private let stageKey = "app_stage_v1"
    
    func loadState() -> RentalState {
        guard let data = defaults.data(forKey: stateKey) else { return RentalState() }
        return (try? JSONDecoder().decode(RentalState.self, from: data)) ?? RentalState()
    }
    
    func saveState(_ state: RentalState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: stateKey)
        }
    }
    
    func loadProfile() -> UserProfile {
        guard let data = defaults.data(forKey: profileKey) else { return UserProfile() }
        return (try? JSONDecoder().decode(UserProfile.self, from: data)) ?? UserProfile()
    }
    
    func saveProfile(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: profileKey)
        }
    }
    
    func loadStage() -> AppStage {
        if let raw = defaults.string(forKey: stageKey), let s = AppStage(rawValue: raw) { return s }
        return .auth
    }
    
    func saveStage(_ stage: AppStage) { defaults.set(stage.rawValue, forKey: stageKey) }
}

// MARK: - Notification Manager

final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }
    
    func schedule(title: String, body: String, date: Date, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification error: \(error)") }
        }
    }
}

// MARK: - Location Manager

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastKnownLocation: CLLocation?
    @Published var resolvedPlacemark: String = ""
    
    override init() {
        super.init()
        manager.delegate = self
    }
    
    func request() {
        if CLLocationManager.locationServicesEnabled() {
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        self.lastKnownLocation = loc
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let p = placemarks?.first else { return }
            let city = p.locality ?? ""
            let state = p.administrativeArea ?? ""
            let country = p.isoCountryCode ?? p.country ?? ""
            let parts = [city, state, country].filter { !$0.isEmpty }
            DispatchQueue.main.async { self?.resolvedPlacemark = parts.joined(separator: ", ") }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}

// MARK: - App Store

@MainActor
final class AppStore: ObservableObject {
    @Published var catalog: [BoardGame] = SampleData.games
    @Published private(set) var activeRentals: [Rental] = []
    @Published private(set) var pastRentals: [Rental] = []
    @Published var profile: UserProfile
    @Published var stage: AppStage
    
    init() {
        let state = Persistence.shared.loadState()
        self.activeRentals = state.active
        self.pastRentals = state.past
        self.profile = Persistence.shared.loadProfile()
        self.stage = Persistence.shared.loadStage()
    }
    
    private func persist() {
        Persistence.shared.saveState(RentalState(active: activeRentals, past: pastRentals))
        Persistence.shared.saveProfile(profile)
        Persistence.shared.saveStage(stage)
    }
    
    func signedIn(name: String?, email: String?) {
        if let n = name { profile.name = n }
        if let e = email { profile.email = e }
        stage = .location
        persist()
    }
    
    func setLocation(_ location: String) {
        profile.location = location
        stage = .main
        persist()
    }
    
    func createRental(for game: BoardGame, pickup: Date, days: Int) {
        let returnDate = Calendar.current.date(byAdding: .day, value: days, to: pickup) ?? pickup
        let daily = game.dailyPrice
        let deposit = game.deposit
        let total = daily * Double(days) + deposit
        let rental = Rental(id: UUID(), game: game, pickup: pickup, returnDate: returnDate, days: days, dailyPrice: daily, deposit: deposit, totalPaid: total, status: .booked, paymentStatus: .paid)
        activeRentals.append(rental)
        persist()
        
        let pickupReminder = Calendar.current.date(byAdding: .hour, value: -1, to: pickup) ?? pickup
        NotificationManager.shared.schedule(title: "Pickup reminder", body: "Pick up \(game.title) by your scheduled time.", date: pickupReminder, id: "pickup_\(rental.id)")
        var returnComponents = Calendar.current.dateComponents([.year, .month, .day], from: returnDate)
        returnComponents.hour = 18
        let returnAtSix = Calendar.current.date(from: returnComponents) ?? returnDate
        NotificationManager.shared.schedule(title: "Return due today", body: "Please return \(game.title) by end of day.", date: returnAtSix, id: "return_\(rental.id)")
    }
    
    func markPickedUp(_ rental: Rental) {
        if let idx = activeRentals.firstIndex(of: rental) {
            activeRentals[idx].status = .pickedUp
            persist()
        }
    }
    
    func markReturned(_ rental: Rental) {
        guard let idx = activeRentals.firstIndex(of: rental) else { return }
        var r = activeRentals.remove(at: idx)
        r.status = .returned
        r.paymentStatus = .refunded
        pastRentals.insert(r, at: 0)
        persist()
    }
}

// MARK: - Sample Data

enum SampleData {
    static let games: [BoardGame] = [
        BoardGame(
            id: UUID(),
            title: "Catan",
            genre: .strategy,
            minPlayers: 3,
            maxPlayers: 4,
            minAge: 10,
            difficulty: .medium,
            dailyPrice: 7.99,
            deposit: 25,
            imageName: "Catan",
            description: "Trade, build, and settle the island of Catan. Manage resources and outsmart your opponents.",
            rating: 4.6
        ),
        BoardGame(
            id: UUID(),
            title: "Ticket to Ride",
            genre: .family,
            minPlayers: 2,
            maxPlayers: 5,
            minAge: 8,
            difficulty: .easy,
            dailyPrice: 6.99,
            deposit: 20,
            imageName: "Tikcet to Ride",
            description: "Collect cards, claim railway routes, and connect cities across the map.",
            rating: 4.7
        ),
        BoardGame(
            id: UUID(),
            title: "Pandemic",
            genre: .cooperative,
            minPlayers: 2,
            maxPlayers: 4,
            minAge: 8,
            difficulty: .medium,
            dailyPrice: 7.49,
            deposit: 25,
            imageName: "Pandemic",
            description: "Work together to stop global outbreaks. Each player has a unique role to help cure diseases.",
            rating: 4.5
        ),
        BoardGame(
            id: UUID(),
            title: "Codenames",
            genre: .party,
            minPlayers: 4,
            maxPlayers: 8,
            minAge: 10,
            difficulty: .easy,
            dailyPrice: 5.49,
            deposit: 15,
            imageName: "Codenames",
            description: "Give one-word clues to help your team find the right agents before the other team.",
            rating: 4.4
        ),
        BoardGame(
            id: UUID(),
            title: "Chess",
            genre: .abstract,
            minPlayers: 2,
            maxPlayers: 2,
            minAge: 6,
            difficulty: .hard,
            dailyPrice: 4.99,
            deposit: 30,
            imageName: "Chess",
            description: "Classic strategy game. Outmaneuver your opponent and checkmate the king.",
            rating: 4.9
        )
    ]
}

// MARK: - Helpers

extension Double {
    func asCurrency(code: String = "USD") -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.string(from: NSNumber(value: self)) ?? String(format: "$%.2f", self)
    }
}

struct RatingView: View {
    var rating: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Image(systemName: i < Int(rating.rounded()) ? "star.fill" : "star")
                    .imageScale(.small)
            }
        }
        .accessibilityLabel("Rating \(String(format: "%.1f", rating)) out of 5")
    }
}

// MARK: - Onboarding Views

struct AuthView: View {
    @EnvironmentObject var store: AppStore

    // Step 1: choose provider; Step 2: collect email/password
    private enum AuthStep { case chooser, email }
    @State private var step: AuthStep = .chooser

    @State private var email = ""
    @State private var password = ""
    @State private var pendingName: String? = nil   // "Apple User" / "Google User" / nil

    // Local gradient so this compiles even if you didn't add a Color extension
    private var bgGradient: LinearGradient {
        LinearGradient(colors: [.purple, .blue, .pink],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            bgGradient.ignoresSafeArea() // colorful background

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "dice.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)

                Text("Board Rental")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text(step == .chooser
                     ? "Sign up or sign in to continue"
                     : "Enter your email and password")
                    .foregroundStyle(.white.opacity(0.8))

                switch step {
                case .chooser:
                    // Sign in with Apple (mock -> then email/password)
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { _ in
                        pendingName = "Apple User"
                        withAnimation { step = .email }
                    }
                    .signInWithAppleButtonStyle(.white) // contrasts on purple bg
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Google (mock -> then email/password)
                    Button {
                        pendingName = "Google User"
                        withAnimation { step = .email }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "g.circle")
                            Text("Continue with Google")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    // Email -> go to email/password
                    Button("Continue with Email") {
                        pendingName = nil
                        withAnimation { step = .email }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                case .email:
                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(.primary)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(.primary)

                        Button {
                            guard !email.isEmpty, !password.isEmpty else { return }
                            // Only now advance to location
                            store.signedIn(name: pendingName, email: email)
                        } label: {
                            Text("Continue")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Back") {
                            withAnimation { step = .chooser }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .transition(.opacity)
                    .padding(.top, 4)
                }

                Spacer()

                Text("By continuing you agree to our Terms & Privacy Policy.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom)
            }
            .padding()
        }
        .preferredColorScheme(.dark) // optional: keeps text legible on bright gradients
    }
}


    struct LocationCaptureView: View {
        @EnvironmentObject var store: AppStore
        @StateObject private var loc = LocationManager()
        @State private var manualLocation: String = ""
        
        var body: some View {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "location.circle.fill").font(.system(size: 64))
                Text("Share your location")
                    .font(.title.weight(.semibold))
                Text("We use your city to show nearby pickup options and tailor availability.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                
                if !loc.resolvedPlacemark.isEmpty {
                    LabeledContent("Detected", value: loc.resolvedPlacemark)
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
                HStack {
                    Button {
                        loc.request()
                    } label: {
                        Label("Use my location", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Skip") { store.setLocation("") }
                        .buttonStyle(.bordered)
                }
                
                Text("Or enter manually")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("City, State, Country", text: $manualLocation)
                    .textFieldStyle(.roundedBorder)
                Button("Save location") {
                    let chosen = !loc.resolvedPlacemark.isEmpty ? loc.resolvedPlacemark : manualLocation
                    store.setLocation(chosen)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
            .onChange(of: loc.resolvedPlacemark) { new in
                if !new.isEmpty { store.setLocation(new) }
            }
        }
}

// MARK: - Main App Views

struct RootView: View {
    @EnvironmentObject var store: AppStore
    
    var body: some View {
        TabView {
            NavigationStack { CatalogView() }
                .tabItem { Label("Catalog", systemImage: "square.grid.2x2") }
            NavigationStack { ActiveRentalsView() }
                .tabItem { Label("Active", systemImage: "clock.badge.checkmark") }
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .onAppear { NotificationManager.shared.requestAuthorization() }
    }
}

struct CatalogView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var selectedGenre: Genre? = nil
    @State private var showLocationChanger = false

    var filtered: [BoardGame] {
        store.catalog.filter { game in
            let matchSearch = search.isEmpty || game.title.localizedCaseInsensitiveContains(search)
            let matchGenre = selectedGenre == nil || game.genre == selectedGenre
            return matchSearch && matchGenre
        }
    }

    var body: some View {
        ZStack {
            // background gradient
            LinearGradient(
                colors: [.purple.opacity(0.2), .blue.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Location bar with dropdown
                if !store.profile.location.isEmpty {
                    Button(action: { showLocationChanger = true }) {
                        HStack {
                            Image(systemName: "mappin.and.ellipse")
                            Text(store.profile.location)
                                .font(.footnote)
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top)
                    }
                    .sheet(isPresented: $showLocationChanger) {
                        LocationChangerView(currentLocation: store.profile.location) { newLoc in
                            store.setLocation(newLoc)
                            showLocationChanger = false
                        }
                    }
                }

                // Search + filter row
                HStack {
                    TextField("Search games", text: $search)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Menu {
                        Button("All Genres") { selectedGenre = nil }
                        Divider()
                        ForEach(Genre.allCases) { g in
                            Button(g.rawValue) { selectedGenre = g }
                        }
                    } label: {
                        Label(selectedGenre?.rawValue ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                .padding([.horizontal, .top])

                // Main list with Active Rentals section first, then Catalog
                List {
                    if !store.activeRentals.isEmpty {
                        Section("Your Active Rentals") {
                            ForEach(store.activeRentals) { rental in
                                NavigationLink(destination: RentalDetailView(rental: rental)) {
                                    RentalRow(rental: rental)
                                }
                            }
                            NavigationLink {
                                ActiveRentalsView()
                            } label: {
                                Label("View all active rentals", systemImage: "clock.badge.checkmark")
                                    .font(.subheadline)
                            }
                        }
                    }

                    Section("Catalog") {
                        if filtered.isEmpty {
                            ContentUnavailableView(
                                "No games",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different search or filter.")
                            )
                            .listRowInsets(EdgeInsets())
                        } else {
                            ForEach(filtered) { game in
                                NavigationLink(value: game) {
                                    GameRow(game: game)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationDestination(for: BoardGame.self) { game in
                    GameDetailView(game: game)
                }
                .navigationTitle("Board Games")
            }
        }
    }
}



struct LocationChangerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manualLocation: String = ""
    let currentLocation: String
    let onSave: (String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Current Location") {
                    Text(currentLocation.isEmpty ? "Not set" : currentLocation)
                }
                Section("Change Location") {
                    TextField("City, State, Country", text: $manualLocation)
                    Button("Use this location") {
                        if !manualLocation.isEmpty {
                            onSave(manualLocation)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Change Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct GameRow: View {
    let game: BoardGame
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .shadow(color: .gray.opacity(0.3), radius: 5, x: 0, y: 3)
                Image(game.imageName)   // 👈 now uses your Assets
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
            .frame(width: 72, height: 72)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(game.title)
                    .font(.headline)
                Text("\(game.genre.rawValue) • \(game.playersText) • \(game.ageText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    RatingView(rating: game.rating)
                    Spacer()
                    Text("\(game.dailyPrice.asCurrency()) / day")
                        .font(.subheadline)
                        .bold()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct GameDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var showRentSheet = false
    let game: BoardGame
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(game.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text(game.title)
                        .font(.largeTitle.bold())
                    HStack(spacing: 8) {
                        Text(game.genre.rawValue)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                        Text(game.difficulty.rawValue)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }
                    Text("\(game.playersText) · \(game.ageText)")
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Price per day")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(game.dailyPrice.asCurrency())
                                .font(.title3).bold()
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("Refundable deposit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(game.deposit.asCurrency())
                                .font(.title3).bold()
                        }
                    }
                    
                    Text(game.description)
                        .padding(.top, 4)
                }
                .padding(.horizontal)
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(action: { showRentSheet = true }) {
                    Label("Rent this game", systemImage: "creditcard")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
        }
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRentSheet) {
            RentalFlowView(game: game)
                .presentationDetents([.medium, .large])
        }
    }
}

struct ZstackImage: View {
    let name: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .padding(40)
        }
        .frame(height: 220)
        .padding(.horizontal)
    }
}

struct RentalFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore
    
    let game: BoardGame
    @State private var pickup = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    @State private var days: Int = 2
    @State private var showingPaidAlert = false
    
    private var total: Double { game.dailyPrice * Double(days) + game.deposit }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Schedule") {
                    DatePicker("Pickup", selection: $pickup, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Stepper(value: $days, in: 1...14) {
                        Text("Days: \(days)")
                    }
                }
                
                Section("Summary") {
                    HStack { Text("Daily price"); Spacer(); Text(game.dailyPrice.asCurrency()) }
                    HStack { Text("Days"); Spacer(); Text("\(days)") }
                    HStack { Text("Subtotal"); Spacer(); Text((game.dailyPrice * Double(days)).asCurrency()) }
                    HStack { Text("Refundable deposit"); Spacer(); Text(game.deposit.asCurrency()) }
                    HStack { Text("Total due now").bold(); Spacer(); Text(total.asCurrency()).bold() }
                }
                
                Section {
                    Button {
                        store.createRental(for: game, pickup: pickup, days: days)
                        showingPaidAlert = true
                    } label: {
                        Label("Confirm & Pay (Mock)", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("Payment uses a mock flow for demo purposes. Deposit is refunded automatically when you mark the rental as returned.")
                }
            }
            .navigationTitle("Confirm Rental")
            .alert("Payment successful", isPresented: $showingPaidAlert) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your rental has been created. We'll remind you on pickup and return days.")
            }
        }
    }
}

struct ActiveRentalsView: View {
    @EnvironmentObject var store: AppStore
    
    var body: some View {
        if store.activeRentals.isEmpty {
            ContentUnavailableView("No active rentals", systemImage: "tray", description: Text("Rent a game to see it here."))
                .navigationTitle("Active Rentals")
        } else {
            List {
                ForEach(store.activeRentals) { rental in
                    NavigationLink(destination: RentalDetailView(rental: rental)) {
                        RentalRow(rental: rental)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Active Rentals")
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if store.pastRentals.isEmpty {
            ContentUnavailableView("No past rentals", systemImage: "clock.arrow.circlepath", description: Text("Finished rentals will appear here."))
                .navigationTitle("History")
        } else {
            List(store.pastRentals) { rental in
                RentalRow(rental: rental)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("History")
        }
    }
}

struct RentalRow: View {
    let rental: Rental
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                Image(systemName: rental.game.imageName)
                    .resizable().scaledToFit().padding(14)
            }
            .frame(width: 60, height: 60)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(rental.game.title).font(.headline)
                Text("Pickup: \(rental.pickup.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Due: \(rental.returnDate.formatted(date: .abbreviated, time: .omitted)) (\(rental.days)d)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(rental.totalPaid.asCurrency()).bold()
                Text(rental.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RentalDetailView: View {
    @EnvironmentObject var store: AppStore
    let rental: Rental
    @State private var showReturnConfirm = false
    
    var body: some View {
        Form {
            Section("Game") {
                HStack {
                    Image(systemName: rental.game.imageName)
                        .frame(width: 28)
                    Text(rental.game.title)
                    Spacer()
                    RatingView(rating: rental.game.rating)
                }
                Text(rental.game.description)
                    .font(.callout)
            }
            
            Section("Schedule") {
                LabeledContent("Pickup", value: rental.pickup.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Return", value: rental.returnDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Days", value: "\(rental.days)")
            }
            
            Section("Payment") {
                LabeledContent("Daily price", value: rental.dailyPrice.asCurrency())
                LabeledContent("Deposit", value: rental.deposit.asCurrency())
                LabeledContent("Total paid", value: rental.totalPaid.asCurrency())
                LabeledContent("Status", value: rental.paymentStatus.rawValue.capitalized)
            }
            
            if rental.status != .returned {
                Section {
                    Button(role: .destructive) { showReturnConfirm = true } label: {
                        Label("Mark as Returned & Refund Deposit", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }
        }
        .navigationTitle("Rental Details")
        .alert("Confirm return?", isPresented: $showReturnConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm") { store.markReturned(rental) }
        } message: {
            Text("We'll move this rental to History and mark the deposit as refunded.")
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    @State private var location: String = ""
    
    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: Binding(
                    get: { name.isEmpty ? store.profile.name : name },
                    set: { name = $0; store.profile.name = $0 }
                ))
                TextField("Email", text: Binding(
                    get: { email.isEmpty ? store.profile.email : email },
                    set: { email = $0; store.profile.email = $0 }
                ))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                TextField("Phone", text: Binding(
                    get: { phone.isEmpty ? store.profile.phone : phone },
                    set: { phone = $0; store.profile.phone = $0 }
                ))
                .keyboardType(.phonePad)
                TextField("Location (City, State, Country)", text: Binding(
                    get: { location.isEmpty ? store.profile.location : location },
                    set: { location = $0; store.profile.location = $0 }
                ))
            }
            Section("About") {
                LabeledContent("App Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("This is a demo app for a board‑game rental flow. Payments are mocked; deposits are refunded when you mark a rental as returned.")
            }
            Section {
                Button(role: .destructive) {
                    store.stage = .auth
                    store.profile = UserProfile() // clear profile
                    Persistence.shared.saveStage(.auth)
                    Persistence.shared.saveProfile(store.profile)
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

        }
        .onDisappear { Persistence.shared.saveProfile(store.profile) }
        .navigationTitle("Profile")
    }
}

// MARK: - App Entry

@main
struct BoardRentalApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            Group {
                switch store.stage {
                case .auth: AuthView()
                case .location: LocationCaptureView()
                case .main: RootView()
                }
            }
            .environmentObject(store)
            .tint(.black)
        }
    }
}

