import SwiftUI
import Combine
import FirebaseAuth
@preconcurrency import FirebaseFirestore

// MARK: - Witness Post Data

struct WitnessPostData {
    let postId: String
    let handle: String
    let text: String
    let tag: String?
    let timeString: String
    let likeCount: Int
    let repostCount: Int
}

// MARK: - Anniversary Post Data

struct AnniversaryPostData {
    let postId: String
    let text: String
    let tag: String?
    let dateString: String
    // Header label rendered at the top of AnniversaryCardView. Drives the
    // four-milestone progression (1mo / 3mo / 6mo / 1yr); previously this
    // was a hardcoded "a year into it" because only the 1-year window was
    // queried. Defaults inferred from milestone walk in fetchAnniversaryPost.
    let milestoneLabel: String
}

// MARK: - FeedViewModel

@MainActor
class FeedViewModel: ObservableObject {

    // MARK: - Tab & Navigation State
        @Published var selectedTab = 0
        @Published var showExplore = false
        @Published var showDailyMoment = false
        @Published var showWitnessPost = false
        @Published var showPromptCompose = false

    // MARK: - Post Data
    @Published var posts: [FeedPost] = []
        @Published var followingPosts: [FeedPost] = []
        @Published var followingFetchIncomplete = false

    // MARK: - Post Metadata (per-post flags keyed by post ID)
    @Published var repostedPostIds: Set<String> = []
    @Published var likedPostIds: Set<String> = []
    @Published var savedPostIds: Set<String> = []
    @Published var postGifUrls: [String: String] = [:]
    var midnightPostIds: Set<String> = []
    var letterPostIds: Set<String> = []
    var whisperPostIds: Set<String> = []
    var repostPostIds: Set<String> = []
    // @Published: tapping "read this letter..." inserts here, and the feed must
    // re-render so the row expands. (As a plain var the insert changed no observed
    // state, so nothing happened on tap.) FeedPostRow is .equatable(), so only the
    // tapped letter re-renders, not the whole feed.
    @Published var expandedLetterIds: Set<String> = []

    // MARK: - Featured Content
    var witnessPost: WitnessPostData? = nil
    var emotionalWeather = ""
    var weatherTag = ""
    var mostUnsaidText = ""
    var mostUnsaidLikes = 0
    var mostUnsaidPostId = ""
    var anniversaryPost: AnniversaryPostData? = nil
    var hasDailyMoment = false

    // MARK: - Fetch State
    // Simple in-flight flag so fetchPosts callers coalesce instead of stacking
    // duplicate Firestore queries on rapid trigger (onAppear + notification, etc).
    var isFetchingPosts = false

    // MARK: - Error State
    @Published var fetchError: String? = nil

    // MARK: - Pagination
    var lastDocument: DocumentSnapshot? = nil
    var isLoadingMore = false
    var hasMorePosts = true
    var endedDueToBlocking = false

    // MARK: - Lifecycle
        var hasFetchedInitial = false
    @Published var hasLoadedOnce = false
        var lastForegroundFetch: Date? = nil
        @Published var isRefreshing = false
    @Published var dragOffset: CGFloat = 0
        @Published var hasAppeared: Bool = false
        var savedScrollPostId: String? = nil

    // MARK: - Personalization
    var userMood: String? = nil
    // Captured during onboarding's stage step (`OnboardingView.stageStep`)
    // and stored at users/{uid}/private/data.breakupStage. Used by the
    // For You scorer to bias the time-decay floor: fresh-breakup users
    // want recent posts; year+ / months-in users want reflective ones
    // that have aged well to keep showing up. nil for accounts that
    // haven't been through the stage step yet — the scorer falls back
    // to the original default decay floor in that case.
    var userBreakupStage: String? = nil
    var engagedTags: [String: Int] = [:]

    // MARK: - Constants
    let tabs = ["for you", "following"]

    let samplePosts: [FeedPost] = [
            FeedPost(id: "sample_1", handle: "anonymous_291034", text: "its weird how you can just become a stranger to someone who knew what you looked like sleeping", tag: "longing", likes: 847, reposts: 34, replies: 89, time: "2h", authorId: "", isShareable: true),
            FeedPost(id: "sample_2", handle: "anonymous_583021", text: "i dont even want you back i just want the months back", tag: "anger", likes: 1204, reposts: 67, replies: 43, time: "3h", authorId: "", isShareable: true),
            FeedPost(id: "sample_3", handle: "anonymous_104782", text: "somebody will ask me about you one day and ill say \"oh yeah\" like you didnt rewire my entire brain", tag: "regret", likes: 2341, reposts: 112, replies: 156, time: "4h", authorId: "", isShareable: true),
            FeedPost(id: "sample_4", handle: "anonymous_672190", text: "the funniest thing about heartbreak is you still have to like. go to work. and buy groceries. and act normal", tag: "acceptance", likes: 1893, reposts: 89, replies: 201, time: "5h", authorId: "", isShareable: true),
            FeedPost(id: "sample_5", handle: "anonymous_385021", text: "its 3am and im not texting you but i want credit for that", tag: "longing", likes: 3102, reposts: 145, replies: 178, time: "6h", authorId: "", isShareable: true),
            FeedPost(id: "sample_6", handle: "anonymous_910283", text: "you wouldve been the first person i told about how sad i am right now and thats the part that actually kills me", tag: "still love you", likes: 4521, reposts: 203, replies: 312, time: "8h", authorId: "", isShareable: true),
            FeedPost(id: "sample_7", handle: "anonymous_447291", text: "its not that i cant live without you its that everything is just slightly worse now. permanently. like someone turned the brightness down on everything and i cant find the setting", tag: "regret", likes: 6234, reposts: 289, replies: 445, time: "10h", authorId: "", isShareable: true),
            FeedPost(id: "sample_8", handle: "anonymous_662081", text: "i still sleep on my side of the bed even though the whole thing is mine now", tag: "moving on", likes: 2876, reposts: 134, replies: 198, time: "12h", authorId: "", isShareable: true),
        ]

    // MARK: - Daily Writing Prompts

    static let dailyPrompts: [(String, String, String)] = [
            ("its 2am and you cant sleep. what are you thinking about.", "longing", "moon.stars"),
            ("type out the text you almost sent last night", "unsent", "envelope"),
            ("what do you miss that has nothing to do with them as a person. like their dog. or their car. or their kitchen.", "regret", "arrow.uturn.backward"),
            ("are you actually healing or just getting quieter about it", "confusion", "questionmark.circle"),
            ("what would you say if they called right now. no thinking just say it.", "still love you", "heart"),
            ("i dont want to start over with someone new and explain all my shit again. do you feel that.", "moving on", "arrow.right.circle"),
            ("do you think they feel guilty or are you not even something to feel guilty about", "anger", "flame"),
            ("what are you pretending is fine right now", "acceptance", "leaf"),
            ("whats the thing you cant tell anyone because theyd say youre crazy", "longing", "moon.stars"),
            ("write the letter youll never send. start with dear you.", "unsent", "envelope"),
            ("whats something small that still ruins you. a song. a street. a food.", "regret", "arrow.uturn.backward"),
            ("do you miss them or do you miss not being alone. its okay if you dont know.", "confusion", "questionmark.circle"),
            ("say the thing you pretend you dont feel anymore", "still love you", "heart"),
            ("what would it take to feel like a beginning instead of an aftermath.", "moving on", "arrow.right.circle"),
            ("whats the thing you cant forgive them for", "anger", "flame"),
            ("did you eat today. did you sleep. are you drinking water. be honest.", "acceptance", "leaf"),
            ("do you still check their social media. be honest.", "longing", "moon.stars"),
            ("say something you havent said out loud to anyone. not even yourself.", "unsent", "envelope"),
            ("what did they say that you still hear on repeat", "regret", "arrow.uturn.backward"),
            ("i keep thinking maybe if i was different. not even better just different. do you do that too.", "confusion", "questionmark.circle"),
            ("be honest. would you take them back right now if they asked.", "still love you", "heart"),
            ("name the first day you noticed you thought about them less. did it scare you.", "moving on", "arrow.right.circle"),
            ("are you angry or just really really sad. or both.", "anger", "flame"),
            ("you got out of bed today. thats not nothing. say it like it counts.", "acceptance", "leaf"),
            ("what song do you skip now because it ruins you", "longing", "moon.stars"),
            ("type out the message thats been sitting in your drafts for weeks", "unsent", "envelope"),
            ("whats the most pathetic thing youve done since it ended. no judgment here.", "regret", "arrow.uturn.backward"),
            ("the thing nobody understands about what happened is", "confusion", "questionmark.circle"),
            ("do you still love them. you dont have to answer that. but do you.", "still love you", "heart"),
            ("who are you when youre not orbiting them. be honest.", "moving on", "arrow.right.circle"),
            ("say it. the one thing you wouldve screamed if you werent so busy being calm and reasonable", "anger", "flame"),
            ("what is the first thing that tasted good again. even a little.", "acceptance", "leaf"),
            ("whats the thought you have every single morning before you can stop it", "longing", "moon.stars"),
            ("write what you wouldve said if youd picked up the last time they called", "unsent", "envelope"),
            ("whats the last thing that made you cry about it. like actually cry.", "regret", "arrow.uturn.backward"),
            ("how are you. and not the version you tell people.", "confusion", "questionmark.circle"),
            ("if they walked back in tonight. no questions asked. would you let them.", "still love you", "heart"),
            ("i dont want to be brave. i just want to wake up and not reach for my phone first.", "moving on", "arrow.right.circle"),
            ("whats the lie they told that still makes your face hot when you remember it", "anger", "flame"),
            ("name one small thing you did today that you didnt think youd manage.", "acceptance", "leaf"),
            ("do you think about them every day still or just most days", "longing", "moon.stars"),
            ("the apology you never gave. write it now.", "unsent", "envelope"),
            ("whats the thing you wish youd said before they walked out the door", "regret", "arrow.uturn.backward"),
            ("do you even know what you miss anymore. them. or the shape they left.", "confusion", "questionmark.circle"),
            ("be honest. how many of your thoughts still end with them.", "still love you", "heart"),
            ("finish this: the version of me that comes after this is", "moving on", "arrow.right.circle"),
            ("you were so patient with them. who is gonna be patient with you", "anger", "flame"),
            ("youre still here. say what got you through the worst hour.", "acceptance", "leaf"),
            ("finish this: i just want someone to", "longing", "moon.stars"),
            ("finish this: i never told you that", "unsent", "envelope"),
            ("theres a text you never sent. whats in it", "regret", "arrow.uturn.backward"),
            ("some days im fine and i cant tell if thats progress or if i just stopped feeling it.", "confusion", "questionmark.circle"),
            ("you tell people youre over it. who are you actually trying to convince.", "still love you", "heart"),
            ("what do you want to keep, and what are you finally allowed to put down.", "moving on", "arrow.right.circle"),
            ("do you think they ever lie awake feeling sick about it or do they just sleep", "anger", "flame"),
            ("what are you carrying that you could set down just for tonight.", "acceptance", "leaf"),
            ("i think the worst feeling is being forgotten by someone you still remember everything about", "longing", "moon.stars"),
            ("write the text you typed and deleted at 3am", "unsent", "envelope"),
            ("what would you give to have one more ordinary tuesday with them", "regret", "arrow.uturn.backward"),
            ("i keep waiting to understand what went wrong like its a sentence ill finish someday.", "confusion", "questionmark.circle"),
            ("theres a version of you still waiting by the phone. say hi to her.", "still love you", "heart"),
            ("there was a whole life you planned around them. what gets to be yours now.", "moving on", "arrow.right.circle"),
            ("name the thing you forgave that you shouldnt have", "anger", "flame"),
            ("did you go outside today. even to the door. thats allowed to count.", "acceptance", "leaf"),
            ("write the text you typed out and never sent. the one still sitting in drafts.", "longing", "moon.stars"),
            ("say the thing you swallowed so the fight would end", "unsent", "envelope"),
            ("whats the apology you keep rehearsing for no one", "regret", "arrow.uturn.backward"),
            ("youre not sad today. is that healing or is that just monday.", "confusion", "questionmark.circle"),
            ("if love really left. why does their name still do that to your chest.", "still love you", "heart"),
            ("i caught myself laughing today and didnt feel guilty after. is that what this is.", "moving on", "arrow.right.circle"),
            ("youre allowed to be furious. you dont have to be the bigger person tonight", "anger", "flame"),
            ("what felt almost normal today. dont rush past it.", "acceptance", "leaf"),
            ("what would you give for one more ordinary tuesday with them. nothing special. just there.", "longing", "moon.stars"),
            ("if they read your mind right now, what would they find", "unsent", "envelope"),
            ("finish this: i should never have", "regret", "arrow.uturn.backward"),
            ("the last thing they said keeps changing meaning depending on the hour. which version is true.", "confusion", "questionmark.circle"),
            ("would you take the bad days back too. all of them. to have them again.", "still love you", "heart"),
            ("what would you do this week if you werent waiting for them to come back.", "moving on", "arrow.right.circle"),
            ("what did they take that they didnt even want. they just didnt want you to have it", "anger", "flame"),
            ("youve been holding it together for everyone. who holds it for you.", "acceptance", "leaf"),
            ("i still reach for my phone to tell them things. then i remember.", "longing", "moon.stars"),
            ("the goodbye you never got to say. say it.", "unsent", "envelope"),
            ("what did you pretend not to care about that you actually cared about so much", "regret", "arrow.uturn.backward"),
            ("do you miss them or do you miss who you were when they looked at you.", "confusion", "questionmark.circle"),
            ("what part of them do you still defend in your head when no ones around.", "still love you", "heart"),
            ("the thought of explaining my history to someone new makes me tired. tell me it gets lighter.", "moving on", "arrow.right.circle"),
            ("the apology you got was for the wrong thing wasnt it. what did they actually need to say", "anger", "flame"),
            ("what did you let yourself feel today instead of pushing it down.", "acceptance", "leaf"),
            ("whats the smell that brings them back instantly. cologne. their pillow. rain.", "longing", "moon.stars"),
            ("write what you wish youd answered when they asked if you were okay", "unsent", "envelope"),
            ("whats the last thing you lied to them about. and why", "regret", "arrow.uturn.backward"),
            ("i replay the part where it was still good and i cant find the exact second it wasnt.", "confusion", "questionmark.circle"),
            ("youve forgiven them already havent you. you just havent told them.", "still love you", "heart"),
            ("what is one thing thats yours again that used to be ours.", "moving on", "arrow.right.circle"),
            ("how many times did you make excuses for them out loud to people who were trying to warn you", "anger", "flame"),
            ("name the smallest kindness you gave yourself this week.", "acceptance", "leaf"),
            ("be honest. would you take them back tonight if they asked. no questions.", "longing", "moon.stars"),
            ("finish this: the truth is i", "unsent", "envelope"),
            ("theres a version of you that fought harder. what would they have done", "regret", "arrow.uturn.backward"),
            ("are you over it or did you just run out of ways to say youre not.", "confusion", "questionmark.circle"),
            ("if they called and only said your name. what would you do.", "still love you", "heart"),
            ("i dont want a clean slate. i just want to stop flinching at their name.", "moving on", "arrow.right.circle"),
            ("whats the sentence of theirs you replay just to stay angry enough not to text back", "anger", "flame"),
            ("what part of your day didnt hurt. start there.", "acceptance", "leaf"),
            ("what part of their body do you miss the most. not the obvious one.", "longing", "moon.stars"),
            ("type the message youll never have the nerve to send", "unsent", "envelope"),
            ("what do you reread late at night that you know you shouldnt", "regret", "arrow.uturn.backward"),
            ("they texted back warm and then nothing. tell me what that was supposed to mean.", "confusion", "questionmark.circle"),
            ("the feelings you say are gone. where do they go at 2am.", "still love you", "heart"),
            ("when did the silence in your apartment stop sounding like loss.", "moving on", "arrow.right.circle"),
            ("do they get to keep the version of you that was soft. or are you taking her back", "anger", "flame"),
            ("you made it to right now. what helped, honestly.", "acceptance", "leaf"),
            ("finish this: the worst part of the day is", "longing", "moon.stars"),
            ("what did you want to say at the door but didnt", "unsent", "envelope"),
            ("what did you take for granted right up until it was gone", "regret", "arrow.uturn.backward"),
            ("im not crying anymore and i dont know if thats relief or something worse.", "confusion", "questionmark.circle"),
            ("would you ruin all this peace just to feel them next to you once more.", "still love you", "heart"),
            ("finish this: i used to dread the mornings, but lately", "moving on", "arrow.right.circle"),
            ("you gave them the benefit of the doubt every single time. tally it up now", "anger", "flame"),
            ("what are you still pretending you dont miss.", "acceptance", "leaf"),
            ("do you still know their number by heart. do you ever almost dial it.", "longing", "moon.stars"),
            ("write the version of i love you you couldnt say back then", "unsent", "envelope"),
            ("finish this: if id only", "regret", "arrow.uturn.backward"),
            ("do you want them back or do you just want the not-knowing to stop.", "confusion", "questionmark.circle"),
            ("be honest. do you still say goodnight to them in your head.", "still love you", "heart"),
            ("what would it take to stop measuring time in how long since they left.", "moving on", "arrow.right.circle"),
            ("what would you say to their face if you knew theyd actually have to sit there and hear it", "anger", "flame"),
            ("did you laugh today. even once. it doesnt mean youre okay but its something.", "acceptance", "leaf"),
            ("what did their laugh sound like. try to write it before you forget.", "longing", "moon.stars"),
            ("the question you were too scared to ask them. ask it here.", "unsent", "envelope"),
            ("whats the thing they asked you for that you didnt give them", "regret", "arrow.uturn.backward"),
            ("theres a version of me from before that i cant get back to. do you ever look for yours.", "confusion", "questionmark.circle"),
            ("if they were happy without you. could you actually be glad. could you.", "still love you", "heart"),
            ("youre allowed to want a future that doesnt include them. say it out loud.", "moving on", "arrow.right.circle"),
            ("theyre out there telling their side. whats the part theyre leaving out", "anger", "flame"),
            ("what would it look like to be gentle with yourself for the next ten minutes.", "acceptance", "leaf"),
            ("i keep their side of the bed cold and untouched like theyre coming back.", "longing", "moon.stars"),
            ("type out what you rehearsed in the shower but never said", "unsent", "envelope"),
            ("what street do you go out of your way to avoid now", "regret", "arrow.uturn.backward"),
            ("i thought i knew them. now i dont know which year was the lie.", "confusion", "questionmark.circle"),
            ("you stopped texting them. you didnt stop writing the texts though.", "still love you", "heart"),
            ("name a small forward thing you did today that nobody would even notice.", "moving on", "arrow.right.circle"),
            ("how dare they be fine. say that. how dare they", "anger", "flame"),
            ("name one thing your body needs that you keep ignoring.", "acceptance", "leaf"),
            ("whats the last thing they said to you. is it the last thing youll ever hear.", "longing", "moon.stars"),
            ("finish this: what i really meant was", "unsent", "envelope"),
            ("whats the smell that drops you straight back into their bed", "regret", "arrow.uturn.backward"),
            ("how do you grieve something youre not even sure is over.", "confusion", "questionmark.circle"),
            ("what would you give to be the one they think of first again.", "still love you", "heart"),
            ("i dont want to start dating. i dont want to be alone either. where does that leave me.", "moving on", "arrow.right.circle"),
            ("whats the thing they did that you laughed off then that you want to throw across the room now", "anger", "flame"),
            ("whats the first song you could listen to again without crying.", "acceptance", "leaf"),
            ("do you talk to them in your head still. what do you tell them.", "longing", "moon.stars"),
            ("write the confession you keep behind your teeth", "unsent", "envelope"),
            ("what did you say in the last fight that you cant take back", "regret", "arrow.uturn.backward"),
            ("the mixed signals werent confusing to them. only to me. i think.", "confusion", "questionmark.circle"),
            ("if loving them was a mistake. why would you make it again. you would.", "still love you", "heart"),
            ("what part of yourself did you bury for them that you want back.", "moving on", "arrow.right.circle"),
            ("did they ever once choose you when it cost them something. or only when it was free", "anger", "flame"),
            ("you cleaned one thing. you answered one text. what got done. be proud quietly.", "acceptance", "leaf"),
            ("what date is burned into you. the day it ended or the day it was good.", "longing", "moon.stars"),
            ("say what you couldnt say while they were still listening", "unsent", "envelope"),
            ("theres a moment you keep going back to. which one. what would you change", "regret", "arrow.uturn.backward"),
            ("am i healing or have i just gotten good at the days when nobody asks.", "confusion", "questionmark.circle"),
            ("theres a sentence youve never said to them. say it here. just once.", "still love you", "heart"),
            ("the day you stop checking if theyve seen it. what does that day look like.", "moving on", "arrow.right.circle"),
            ("youre not crazy. you were never crazy. who made you doubt that and do you still let them", "anger", "flame"),
            ("what are you tired of pretending youre over.", "acceptance", "leaf"),
            ("finish this: i wish i could go back to the moment before", "longing", "moon.stars"),
            ("the words you saved for a conversation that never happened. write them.", "unsent", "envelope"),
            ("what part of them do you still talk to when no ones around", "regret", "arrow.uturn.backward"),
            ("i dont miss them at noon. at 2am im not so sure. which one is real.", "confusion", "questionmark.circle"),
            ("would you still pick them. knowing exactly how it ends. knowing all of it.", "still love you", "heart"),
            ("i keep waiting to feel ready. what if i just go before im ready.", "moving on", "arrow.right.circle"),
            ("what promise of theirs do you want to read back to them word for word", "anger", "flame"),
            ("did you rest today or just stop moving. theres a difference. be honest.", "acceptance", "leaf"),
            ("describe the way they said your name. who says it like that now.", "longing", "moon.stars"),
            ("type the reply you wrote in your head a hundred times", "unsent", "envelope"),
            ("whats the gift of theirs you still keep in a drawer", "regret", "arrow.uturn.backward"),
            ("they said it wasnt about me and i still cant figure out who it was about.", "confusion", "questionmark.circle"),
            ("be honest. is there anyone you compare to them. does anyone win.", "still love you", "heart"),
            ("what would you tell the next person about you, if you werent afraid of scaring them.", "moving on", "arrow.right.circle"),
            ("they got to leave clean and you got the wreckage. wheres the fairness in that", "anger", "flame"),
            ("what small routine is keeping you upright right now.", "acceptance", "leaf"),
            ("do you wonder if theyre lying awake too. or if its just you.", "longing", "moon.stars"),
            ("finish this: i should have told you", "unsent", "envelope"),
            ("what did you stop doing for them that you wish you hadnt", "regret", "arrow.uturn.backward"),
            ("do you actually feel better or did you just lower what better has to mean.", "confusion", "questionmark.circle"),
            ("if they asked for nothing. just to sit with you. would you say yes.", "still love you", "heart"),
            ("finish this: the song that used to wreck me now just feels like", "moving on", "arrow.right.circle"),
            ("whats the comeback you thought of three days too late. say it here instead", "anger", "flame"),
            ("name a moment today you forgot to be sad. let yourself have had it.", "acceptance", "leaf"),
            ("whats the place you avoid now because youll see them there in your head.", "longing", "moon.stars"),
            ("write what you wanted them to know before they walked away", "unsent", "envelope"),
            ("finish this: i was too proud to", "regret", "arrow.uturn.backward"),
            ("i keep rereading the last conversation for a clue i already know isnt there.", "confusion", "questionmark.circle"),
            ("the love didnt leave when they did. what do you do with it now.", "still love you", "heart"),
            ("you survived the version of you that didnt think youd survive. what now.", "moving on", "arrow.right.circle"),
            ("did they make you small so they could feel big. how long did it work", "anger", "flame"),
            ("whats one thing you used to dread that felt okay today.", "acceptance", "leaf"),
            ("i found their hair on a sweater i havent worn in months and i lost it.", "longing", "moon.stars"),
            ("the thing you almost confessed and then changed the subject. confess it now.", "unsent", "envelope"),
            ("whats the order you cant place anymore because it was theirs too", "regret", "arrow.uturn.backward"),
            ("part of me is relieved and i dont know what that says about all of it.", "confusion", "questionmark.circle"),
            ("you keep their old messages. youre not gonna delete them. why.", "still love you", "heart"),
            ("what does a tuesday look like when it isnt about them anymore.", "moving on", "arrow.right.circle"),
            ("what are you still defending them for and who are you protecting really", "anger", "flame"),
            ("you survived the day you didnt think youd survive. how does that sit.", "acceptance", "leaf"),
            ("say the thing you wish you could tell them right now at this exact hour.", "longing", "moon.stars"),
            ("type out the last thing you wish theyd heard from you", "unsent", "envelope"),
            ("what did you almost tell them and then didnt", "regret", "arrow.uturn.backward"),
            ("youre quieter now. is that peace or did you just stop reaching for them.", "confusion", "questionmark.circle"),
            ("if you saw them tomorrow. what would your hands want to do first.", "still love you", "heart"),
            ("i dont miss them today. i miss missing them, which is somehow worse. is it.", "moving on", "arrow.right.circle"),
            ("the worst part isnt that they did it. its that they knew exactly what it would do to you and did it anyway. didnt they", "anger", "flame"),
            ("what are you doing just to get through, and is it kind enough.", "acceptance", "leaf"),
            ("do you still sleep on your side of the bed. why.", "longing", "moon.stars"),
            ("write the message you keep starting and never finishing", "unsent", "envelope"),
            ("whats the date on the calendar that still wrecks you", "regret", "arrow.uturn.backward"),
            ("i cant tell if i forgive them or if i just forgot to keep being angry.", "confusion", "questionmark.circle"),
            ("would you tell them you still love them. if it changed nothing. would you.", "still love you", "heart"),
            ("what are you slowly becoming that they never got to meet.", "moving on", "arrow.right.circle"),
            ("you kept the receipts in your chest for months. dump them out", "anger", "flame"),
            ("did anyone check on you today. did you let them in.", "acceptance", "leaf"),
            ("what habit of theirs do you catch yourself doing now.", "longing", "moon.stars"),
            ("say the part you left out of the goodbye", "unsent", "envelope"),
            ("what would past you be furious at present you for", "regret", "arrow.uturn.backward"),
            ("they were everything and now i cant remember why. that scares me more than missing them.", "confusion", "questionmark.circle"),
            ("be honest. when you say you miss them. do you mean you still want them.", "still love you", "heart"),
            ("the idea of someone new touching the parts they touched. terrifying or freeing. which.", "moving on", "arrow.right.circle"),
            ("what did they call closure that was really just them needing you to be okay so they could feel less guilty", "anger", "flame"),
            ("name the thing that felt like yours again. even for a second.", "acceptance", "leaf"),
            ("be honest. how many times have you typed their name into the search bar tonight.", "longing", "moon.stars"),
            ("finish this: if i had been braver id have said", "unsent", "envelope"),
            ("whats the song you put on just to feel it open back up", "regret", "arrow.uturn.backward"),
            ("do you still love them or is it just the muscle memory of having.", "confusion", "questionmark.circle"),
            ("theres a part of you that never agreed to the breakup. let it speak.", "still love you", "heart"),
            ("name the moment you realized you stopped editing texts you were never going to send.", "moving on", "arrow.right.circle"),
            ("how many of your own needs did you shrink so they wouldnt feel crowded", "anger", "flame"),
            ("what hurts a little less than it did last week. notice it out loud.", "acceptance", "leaf"),
            ("whats the inside joke nobody else will ever understand. who do you tell it to now.", "longing", "moon.stars"),
            ("write what you would text right now if you knew theyd never see it", "unsent", "envelope"),
            ("what did they warn you about that you ignored", "regret", "arrow.uturn.backward"),
            ("nothing they did adds up to leaving and yet here we are.", "confusion", "questionmark.circle"),
            ("if they were standing outside right now. would you open the door.", "still love you", "heart"),
            ("what would it take to walk past their old street without holding your breath.", "moving on", "arrow.right.circle"),
            ("they get to be the one who left. what story did that let them tell about you", "anger", "flame"),
            ("youre allowed to not be fine and still be doing this right.", "acceptance", "leaf"),
            ("i keep waiting for a text that isnt coming and i hate that i still check.", "longing", "moon.stars"),
            ("the words stuck in your throat the whole time. let them out.", "unsent", "envelope"),
            ("whats the chore you used to hate that you miss doing with them", "regret", "arrow.uturn.backward"),
            ("i feel okay and i keep waiting for the okay to turn out fake.", "confusion", "questionmark.circle"),
            ("you pretend it was just a season. but you still water it. dont you.", "still love you", "heart"),
            ("i dont want to forget them. i just want to stop being haunted. is there a difference.", "moving on", "arrow.right.circle"),
            ("whats the thing you bit back every time. let it out, no one here is grading your tone", "anger", "flame"),
            ("what did you make it through without checking their name. say it gently.", "acceptance", "leaf"),
            ("what did it feel like to be wanted by them. do you remember.", "longing", "moon.stars"),
            ("type the truth you hid inside im fine", "unsent", "envelope"),
            ("what did you assume youd have more time for. and then you didnt", "regret", "arrow.uturn.backward"),
            ("which is worse. that they changed. or that maybe they didnt and i just stopped seeing it.", "confusion", "questionmark.circle"),
            ("what would you say if they asked were you ever really over me.", "still love you", "heart"),
            ("finish this: starting over sounds exhausting, but staying here sounds like", "moving on", "arrow.right.circle"),
            ("did they ever say sorry or did they just say they felt bad that you were hurt", "anger", "flame"),
            ("name one thing you can control tonight. just one. start small.", "acceptance", "leaf"),
            ("finish this: the version of me that knew them is", "longing", "moon.stars"),
            ("write what you wanted to scream but said nothing", "unsent", "envelope"),
            ("finish this: the last thing i ever said to them was", "regret", "arrow.uturn.backward"),
            ("im not waiting for them to come back. i think. ask me again tomorrow.", "confusion", "questionmark.circle"),
            ("would you wait. if they asked you to wait. how long. be honest.", "still love you", "heart"),
            ("what habit did you build around them that youre quietly letting die.", "moving on", "arrow.right.circle"),
            ("you werent too much. you were exactly enough and they couldnt handle being seen by someone who was. say it meaner than that", "anger", "flame"),
            ("what are you white-knuckling that you could just let be hard.", "acceptance", "leaf"),
            ("do you miss them. or do you miss who you were when they loved you.", "longing", "moon.stars"),
            ("finish this: theres something i never admitted to you", "unsent", "envelope"),
            ("what do you still buy at the store out of habit for two", "regret", "arrow.uturn.backward"),
            ("the silence felt like an answer for a while. now im not sure it was one.", "confusion", "questionmark.circle"),
            ("the song comes on and you let it play the whole way through. why.", "still love you", "heart"),
            ("youll have to tell someone everything again one day. who do you want them to meet.", "moving on", "arrow.right.circle"),
            ("what did loving them cost you that you only see the bill for now", "anger", "flame"),
            ("did you drink water today. did you take the meds. did you breathe. be honest.", "acceptance", "leaf"),
            ("whats the photo you cant delete but cant look at either.", "longing", "moon.stars"),
            ("say the thing you were saving for the right moment that never came", "unsent", "envelope"),
            ("whats the thing you broke that you cant fix now", "regret", "arrow.uturn.backward"),
            ("do you remember who you were going to be before all of this rerouted you.", "confusion", "questionmark.circle"),
            ("if i love you still lives in you. who is it waiting to reach.", "still love you", "heart"),
            ("when does their absence stop being a wound and start being just a fact.", "moving on", "arrow.right.circle"),
            ("they want to be friends. whats the laugh you held back when they asked", "anger", "flame"),
            ("whats the first plan you made that didnt include them.", "acceptance", "leaf"),
            ("describe the last good night you had together before you knew it was the last.", "longing", "moon.stars"),
            ("type out the message you almost sent and then turned your phone off", "unsent", "envelope"),
            ("what side of the bed do you still not sleep on", "regret", "arrow.uturn.backward"),
            ("some nights i dont miss them at all and that absence is its own kind of strange.", "confusion", "questionmark.circle"),
            ("be honest. do you want them back. or do you want who you were with them.", "still love you", "heart"),
            ("i moved their stuff into a box today. didnt cry. didnt feel good either. what is this.", "moving on", "arrow.right.circle"),
            ("whats the favor you did at 2am that they never even thanked you for", "anger", "flame"),
            ("what did you let yourself enjoy today without guilt.", "acceptance", "leaf"),
            ("i wonder if they kept the thing i gave them. or if its in a drawer somewhere.", "longing", "moon.stars"),
            ("write what you wish youd said instead of okay", "unsent", "envelope"),
            ("whats the night you wish you had just stayed", "regret", "arrow.uturn.backward"),
            ("they apologized for the wrong thing and i never figured out what i was actually owed.", "confusion", "questionmark.circle"),
            ("if they apologized. really apologized. would the love come rushing back.", "still love you", "heart"),
            ("what would you do with the hours you used to spend keeping them happy.", "moving on", "arrow.right.circle"),
            ("you were loyal to someone who was auditioning replacements. how does that sit tonight", "anger", "flame"),
            ("you woke up and chose to keep going. name what that took.", "acceptance", "leaf"),
            ("whats the time of day that hits the hardest. morning. dusk. 2am.", "longing", "moon.stars"),
            ("the sentence you couldnt finish out loud. finish it here.", "unsent", "envelope"),
            ("what did you let get cold and small instead of saying it out loud", "regret", "arrow.uturn.backward"),
            ("am i moving on or just moving. theres a difference and i lost it somewhere.", "confusion", "questionmark.circle"),
            ("you keep saying it was for the best. say what you actually feel.", "still love you", "heart"),
            ("name something you want now that you wouldnt have let yourself want with them.", "moving on", "arrow.right.circle"),
            ("did they break it slow so they could pretend it wasnt them. catch them in it", "anger", "flame"),
            ("what part of you is starting to come back. dont scare it off. just notice.", "acceptance", "leaf"),
            ("do you still wear the thing that smells like them. or did you have to stop.", "longing", "moon.stars"),
            ("type the confession you only make when its dark", "unsent", "envelope"),
            ("what number do you still know by heart that you cant call", "regret", "arrow.uturn.backward"),
            ("i cant tell if i want them or if i just want to not be the one who lost.", "confusion", "questionmark.circle"),
            ("would you trade being right for having them. tonight. yes or no.", "still love you", "heart"),
            ("the future used to have their face in it. whats there now when you squint.", "moving on", "arrow.right.circle"),
            ("what excuse of theirs do you want to set on fire right now", "anger", "flame"),
            ("name the bare minimum you did today and call it enough. because it is.", "acceptance", "leaf"),
            ("say it. you would still pick up if they called right now.", "longing", "moon.stars"),
            ("write what you held back the night everything changed", "unsent", "envelope"),
            ("what did you do the day after that you still cringe about", "regret", "arrow.uturn.backward"),
            ("everyone keeps saying youll understand it later. its later. i dont.", "confusion", "questionmark.circle"),
            ("theres a name your heart still calls home. you dont have to say it. but.", "still love you", "heart"),
            ("i dont want closure. i want to wake up one day and find it already closed. can i.", "moving on", "arrow.right.circle"),
            ("they cried too. but whose tears were performance and whose were the real wound", "anger", "flame"),
            ("what are you pretending doesnt still ache on the quiet days.", "acceptance", "leaf"),
            ("what season reminds you of them and is it coming back around.", "longing", "moon.stars"),
            ("finish this: i never got to tell you that you", "unsent", "envelope"),
            ("whats the plan you two made that you cant unmake in your head", "regret", "arrow.uturn.backward"),
            ("do you miss the person or the future you already lived in your head with them.", "confusion", "questionmark.circle"),
            ("if they reached for your hand right now. would you pull away. would you.", "still love you", "heart"),
            ("finish this: i used to be theirs, and now im slowly becoming", "moving on", "arrow.right.circle"),
            ("how long did you confuse their carelessness for something youd done wrong", "anger", "flame"),
            ("did you eat something real today or just whatever was closest. no judgment.", "acceptance", "leaf"),
            ("i practice what id say if i ran into them. ive practiced it a hundred times.", "longing", "moon.stars"),
            ("say what you wanted to whisper but kept quiet", "unsent", "envelope"),
            ("finish this: i keep thinking if id picked up the phone", "regret", "arrow.uturn.backward"),
            ("i went a whole day without it hurting and then i felt guilty. explain that one to me.", "confusion", "questionmark.circle"),
            ("be honest. how much of moving on is just acting until they cant tell.", "still love you", "heart"),
            ("what is the smallest sign that youre healing that you almost didnt notice.", "moving on", "arrow.right.circle"),
            ("whats the version of events theyll tell their next person about you. correct the record here", "anger", "flame"),
            ("whats one thing that felt steady when everything else didnt.", "acceptance", "leaf"),
            ("whats the food you cant order anymore because it was yours together.", "longing", "moon.stars"),
            ("type the message your hands wrote that your heart deleted", "unsent", "envelope"),
            ("whats the show you still cant watch the rest of without them", "regret", "arrow.uturn.backward"),
            ("is this acceptance or have i just made a home out of being unsure.", "confusion", "questionmark.circle"),
            ("the love you swore you killed. its still breathing isnt it. quietly.", "still love you", "heart"),
            ("you dont have to be over it to start walking. which direction faces away from them.", "moving on", "arrow.right.circle"),
            ("you held the whole thing up alone and they called it a partnership. whats the word you actually want to use", "anger", "flame"),
            ("you got through dinner. through the night. through the morning. what helped.", "acceptance", "leaf"),
            ("do you imagine them happy without you. does it gut you or do you want it for them.", "longing", "moon.stars"),
            ("write the thing you wish theyd known before it was too late", "unsent", "envelope"),
            ("what did you blame on them that was really on you", "regret", "arrow.uturn.backward"),
            ("i dont know if i loved them or loved being chosen. those felt the same until they werent.", "confusion", "questionmark.circle"),
            ("if they said i never stopped. what would you say back. dont think.", "still love you", "heart"),
            ("when did you last make a plan that stretched past the part of your life that had them.", "moving on", "arrow.right.circle"),
            ("did they ever fight for it or did they just let you do all the bleeding", "anger", "flame"),
            ("name a small thing you looked forward to today. it doesnt have to be big.", "acceptance", "leaf"),
            ("finish this: nobody warned me that missing someone could feel like", "longing", "moon.stars"),
            ("the words you owe yourself, not them. write those.", "unsent", "envelope"),
            ("whats the seat at the table thats still theirs in your head", "regret", "arrow.uturn.backward"),
            ("the relationship made sense from the inside. now i cant rebuild the logic of it.", "confusion", "questionmark.circle"),
            ("would you give up the closure just to keep the hope. some of you would.", "still love you", "heart"),
            ("i practiced their name in past tense today. it didnt break me. when did that happen.", "moving on", "arrow.right.circle"),
            ("whats the kindness you showed them that they used as a weapon later", "anger", "flame"),
            ("what are you surviving right now that you wont always have to survive.", "acceptance", "leaf"),
            ("what would you say if you got thirty seconds and they had to listen.", "longing", "moon.stars"),
            ("finish this: what i was too proud to say is", "unsent", "envelope"),
            ("what would you say if they walked in right now and you had ten seconds", "regret", "arrow.uturn.backward"),
            ("do you feel free or just untethered. i keep mixing those two up.", "confusion", "questionmark.circle"),
            ("you still set a place for them somehow. in your head. dont you.", "still love you", "heart"),
            ("what would it take to believe the next chapter isnt just an apology for this one.", "moving on", "arrow.right.circle"),
            ("theyre sleeping fine tonight. that should make you angrier than it makes you sad. does it", "anger", "flame"),
            ("did you let yourself sit still today without filling the quiet. how was it.", "acceptance", "leaf"),
            ("i still set out two mugs sometimes. by accident. by habit. by hope.", "longing", "moon.stars"),
            ("type out the letter you read to no one and then closed", "unsent", "envelope"),
            ("what did you wait too long to forgive them for", "regret", "arrow.uturn.backward"),
            ("i stopped checking their profile and i cant tell if thats strength or surrender.", "confusion", "questionmark.circle"),
            ("if love is a choice. why does it keep choosing them without asking you.", "still love you", "heart"),
            ("what would younger you say if she saw how long you let them stay", "anger", "flame"),
            ("what felt like the first easy breath in a while. hold onto that one.", "acceptance", "leaf"),
            ("whats the word or phrase only they used. do you still hear it.", "longing", "moon.stars"),
            ("write what you couldnt say without breaking, so you said nothing", "unsent", "envelope"),
            ("they came back warm for a week then vanished. i never got to ask which one was them.", "confusion", "questionmark.circle"),
            ("be honest. if they came back changed and real. would you risk it all again.", "still love you", "heart"),
            ("say the thing you keep softening for everyone else. dont soften it here", "anger", "flame"),
            ("do you reread old messages knowing it makes it worse. why do you do it.", "longing", "moon.stars"),
            ("how are you. really. not better, not worse. just whatever this in-between is.", "confusion", "questionmark.circle"),
            ("the thing you most want them to know. youre not over it. write it anyway.", "still love you", "heart"),
            ("what does their absence sound like in your apartment at night.", "longing", "moon.stars"),
            ("be honest. are you waiting for them. how long will you wait.", "longing", "moon.stars"),
            ("whats the dream you keep having where theyre back. how do you feel when you wake.", "longing", "moon.stars"),
            ("i would trade almost anything for the weight of their head on my chest one more time.", "longing", "moon.stars"),
        ]

    // MARK: - Computed Properties

    var currentPosts: [FeedPost] {
        switch selectedTab {
        case 1: return followingPosts.isEmpty ? [] : followingPosts
        default: return posts
        }
    }

    /// Posts for a SPECIFIC feed column, independent of `selectedTab` — used by
    /// the swipeable for-you/following pager so each page renders its own tab.
    func postsForTab(_ tab: Int) -> [FeedPost] {
        tab == 1 ? (followingPosts.isEmpty ? [] : followingPosts) : posts
    }

    var todaysPrompt: (String, String, String) {
        guard !Self.dailyPrompts.isEmpty else {
            return ("how are you, really?", "confusion", "questionmark.circle")
        }
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return Self.dailyPrompts[dayOfYear % Self.dailyPrompts.count]
    }

    /// yyyy-MM-dd string for today, used as the prompt-response marker on
    /// post docs. FeedView passes this into ComposeView when opening the
    /// prompt "respond" flow; the post-create rule allows it as an optional
    /// field on the post doc. Local-time bucket (matches todaysPrompt's
    /// dayOfYear bucket) — both move together if the device timezone changes.
    var todaysPromptDateString: String {
        ToskaFormatters.dateKey.string(from: Date())
    }

    /// The current user's response to today's prompt, if they've answered.
    /// Populated by fetchTodaysPromptResponse(); nil when the user hasn't
    /// responded yet (or hasn't loaded yet). FeedHeaderCard reads this to
    /// flip the prompt card between "respond" and "your response."
    @Published var todaysPromptResponse: FeedPost? = nil

    /// One-shot fetch of the user's response to today's prompt. Cheap (one
    /// query, at most one doc returned) and called on initial load,
    /// pull-to-refresh, and after .newPostCreated so the card updates the
    /// moment a response lands. Server-side dedup isn't enforced here —
    /// rules can't easily check "user already has a doc for today" — so a
    /// tampered client could post multiple times. The client disables the
    /// respond button once a response exists; that's the contract.
    func fetchTodaysPromptResponse() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let today = todaysPromptDateString
        // Capture uid so the post-await write to todaysPromptResponse can
        // verify the same account is still signed in. Without this, a
        // sign-out + sign-in to a different account during the Firestore
        // round-trip would land the previous user's response card on the
        // new user's feed. Mirrors the capturedUid pattern in
        // fetchFollowingPosts / fetchLikedPostIds / startLiveListener.
        let capturedUid = uid
        Task { @MainActor in
            do {
                let snap = try await Firestore.firestore().collection("posts")
                    .whereField("authorId", isEqualTo: uid)
                    .whereField("promptDate", isEqualTo: today)
                    .limit(to: 1)
                    .getDocumentsAsync()
                guard Auth.auth().currentUser?.uid == capturedUid else { return }
                guard let doc = snap.documents.first else {
                    todaysPromptResponse = nil
                    return
                }
                todaysPromptResponse = FeedView.feedPost(from: doc)
            } catch {
                print("⚠️ fetchTodaysPromptResponse failed: \(error)")
                // Leave existing value alone on transient error.
            }
        }
    }

    var promptTimeLabel: String {
        "\(timeOfDayLabel())'s prompt"
    }

    var timeGreeting: String {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 0 && hour < 5 { return "still up?" }
            else if hour < 9 { return "how did you sleep. honestly." }
            else if hour < 12 { return "one hour at a time." }
            else if hour < 17 { return "still here." }
            else if hour < 21 { return "made it through the day." }
            else { return "its late. were here." }
        }

    var dailyMomentLabel: String {
        "\(timeOfDayLabel())'s moment"
    }

    // MARK: - Initial Load

    
    var supplementaryTask: Task<Void, Never>? = nil

        func loadInitialData() {
            print("⚡️ loadInitialData called — hasFetchedInitial: \(hasFetchedInitial), hasAuth: \(Auth.auth().currentUser != nil)")
            guard !hasFetchedInitial else {
                print("⚡️ loadInitialData — already fetched, posts.count: \(posts.count)")
                if posts.isEmpty {
                    fetchPosts()
                }
                return
            }
            guard Auth.auth().currentUser != nil else {
                print("🛑 loadInitialData — auth is nil, should not happen after isLoggedIn=true")
                return
            }
            hasFetchedInitial = true
                                lastForegroundFetch = Date()
                                savedScrollPostId = nil
                                print("⚡️ loadInitialData — proceeding with fetch")

            supplementaryTask?.cancel()
                    supplementaryTask = Task { @MainActor in
                        self.refreshAll()
                        guard !Task.isCancelled, Auth.auth().currentUser != nil else { return }
                        self.fetchUserPreferences()
                        guard !Task.isCancelled, Auth.auth().currentUser != nil else { return }
                        self.fetchAnniversaryPost()
                    }
                }

    func cancelAllTasks() {
            supplementaryTask?.cancel()
            supplementaryTask = nil
            followingTask?.cancel()
            followingTask = nil
            userPreferencesTask?.cancel()
            userPreferencesTask = nil
            likedListener?.remove()
            likedListener = nil
            savedListener?.remove()
            savedListener = nil
            repostedListener?.remove()
            repostedListener = nil
            hasFetchedInitial = false
        hasLoadedOnce = false
        posts = []
        followingPosts = []
        likedPostIds = []
        savedPostIds = []
        repostedPostIds = []
        fetchError = nil
                savedScrollPostId = nil
                dragOffset = 0
            }

    func handleNewPostCreated() {
        fetchPosts()
        fetchMostUnsaidAndDailyMoment()
        // Refresh the prompt-response state — if the new post WAS today's
        // prompt response, the header card needs to flip from "respond" to
        // the response card with edit/delete.
        fetchTodaysPromptResponse()
    }

    // Called from FeedView in response to .userBlocked so the blocked user's
    // posts vanish from the in-memory feed immediately, without waiting for
    // the next refresh to re-run filterBlocked.
    func handleUserBlocked(userId: String) {
        guard !userId.isEmpty else { return }
        let isBlockedAuthor: (FeedPost) -> Bool = { $0.authorId == userId }
        posts.removeAll(where: isBlockedAuthor)
        followingPosts.removeAll(where: isBlockedAuthor)
        // postGifUrls/midnightPostIds/etc. are keyed by postId, not by
        // authorId, so we can't prune by uid directly. Fall through to
        // trimPostMetadata which intersects all metadata stores with the
        // current posts array (after the removeAll above), dropping any
        // stale entries for the blocked author's posts.
        trimPostMetadata()
        // repostedPostIds / likedPostIds / savedPostIds are per-post, not
        // per-author, and self-heal via their snapshot listeners — no need
        // to prune them here.
    }

    func handleInteractionChanged(_ info: [AnyHashable: Any]) {
        guard let postId = info["postId"] as? String,
              let action = info["action"] as? String,
              let value = info["value"] as? Bool else { return }
        switch action {
        case "like":
            if value { likedPostIds.insert(postId) } else { likedPostIds.remove(postId) }
        case "save":
            if value { savedPostIds.insert(postId) } else { savedPostIds.remove(postId) }
        case "repost":
            // Mirror likes/saves — without this, a repost tapped from
            // PostDetailView or the feed's context menu doesn't flip the
            // repost state on other rendered copies of the same post, so
            // the button stays in its pre-action state until a full refresh.
            if value { repostedPostIds.insert(postId) } else { repostedPostIds.remove(postId) }
        default: break
        }
    }

    func handleForegroundReturn() {
            LateNightThemeManager.shared.refresh()
            guard hasFetchedInitial else { return }
            if let last = lastForegroundFetch, Date().timeIntervalSince(last) < 60 { return }
            lastForegroundFetch = Date()
            fetchError = nil
            fetchPosts()
            fetchFollowingPosts()
        }

    // MARK: - Refresh All

    func refreshAll() {
                fetchError = nil
                fetchRepostedPostIds()
                fetchLikedPostIds()
                fetchSavedPostIds()
                fetchPosts()
                fetchFollowingPosts()
                fetchWitnessPost()
                fetchEmotionalWeather()
                fetchMostUnsaidAndDailyMoment()
                fetchAnniversaryPost()
                fetchTodaysPromptResponse()
            }

    /// Lean pull-to-refresh: only the visible feed content + today's prompt
    /// response. The like/save/repost state is already kept live by snapshot
    /// listeners (no re-fetch needed), and the decorative extras (weather,
    /// witness, daily-moment, anniversary) load once on appear via refreshAll().
    /// Re-running all of those on every pull churned the header and burned reads,
    /// which is what made the refresh feel unclean — this keeps it to the content
    /// that actually changes.
    func refreshFeed() {
        fetchError = nil
        fetchPosts()
        fetchFollowingPosts()
        fetchTodaysPromptResponse()
        // The anniversary card is rendered + time-windowed + deletable, so it must
        // re-fetch on pull (else a rolled-over window or a deleted-elsewhere
        // anniversary stays stale until cold launch). The other decorative extras
        // aren't surfaced in the current header, so they stay on the appear-load.
        fetchAnniversaryPost()
    }

    // MARK: - Fetch User Interaction States

    // Snapshot listeners keep likedPostIds / savedPostIds / repostedPostIds
    // continuously in sync with Firestore. Each listener fires only on the
    // delta since its last snapshot, so a like added on another device shows
    // up immediately here without a refresh, and pull-to-refresh no longer
    // re-fetches 500 docs per call (previous pattern burned ~1500 reads per
    // refresh across these three). Listeners are idempotent — subsequent
    // fetch*() calls with a listener already attached are no-ops; they are
    // torn down and reset in cancelAllTasks on sign-out.
    private var likedListener: ListenerRegistration? = nil
    private var savedListener: ListenerRegistration? = nil
    private var repostedListener: ListenerRegistration? = nil

    func fetchLikedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard likedListener == nil else { return }
        // Capture uid so the callback can verify it's still serving the same
        // account before mutating @Published state. Without this, an in-flight
        // snapshot fired after a sign-out/sign-in for a different user can
        // write the previous user's liked set into the new user's UI.
        let capturedUid = uid
        likedListener = Firestore.firestore()
            .collection("users").document(uid).collection("liked")
            .order(by: "createdAt", descending: true)
            .limit(to: 500)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    self.likedPostIds = Set(snapshot?.documents.map { $0.documentID } ?? [])
                }
            }
    }

    func fetchSavedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard savedListener == nil else { return }
        let capturedUid = uid
        savedListener = Firestore.firestore()
            .collection("users").document(uid).collection("saved")
            .order(by: "createdAt", descending: true)
            .limit(to: 500)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    self.savedPostIds = Set(snapshot?.documents.map { $0.documentID } ?? [])
                }
            }
    }

    func fetchRepostedPostIds() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard repostedListener == nil else { return }
        let capturedUid = uid
        repostedListener = Firestore.firestore()
            .collection("posts")
            .whereField("authorId", isEqualTo: uid)
            .whereField("isRepost", isEqualTo: true)
            .order(by: "createdAt", descending: true)
            .limit(to: 200)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          Auth.auth().currentUser?.uid == capturedUid else { return }
                    let ids = snapshot?.documents.compactMap { $0.data()["originalPostId"] as? String } ?? []
                    self.repostedPostIds = Set(ids)
                }
            }
    }

    // MARK: - Fetch User Preferences for For You

    // Task storage so rapid repeat calls (e.g. loadInitialData → refreshAll in
    // quick succession) cancel any prior in-flight preferences fetch before
    // starting a new one. Previously there was no cancellation guard and no
    // task storage, so two concurrent fetches each ran the TaskGroup-based
    // tag rollup and their increments were both applied to engagedTags —
    // doubling counts. The new version also assigns engagedTags rather than
    // incrementing into it, which makes repeat fetches idempotent.
    private var userPreferencesTask: Task<Void, Never>? = nil

    func fetchUserPreferences() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        userPreferencesTask?.cancel()
        userPreferencesTask = Task { @MainActor [weak self] in
            let db = Firestore.firestore()

            // Mood lives in users/{uid}/private/data going forward (owner-only)
            // so it isn't readable by other authenticated users via the public
            // users-doc rule. Older accounts may still have it on the main doc;
            // fall back there until OnboardingView/SettingsView writes the new
            // location and the legacy field gets cleared.
            async let mainSnap = try? db.collection("users").document(uid).getDocumentAsync()
            async let privateSnap = try? db.collection("users").document(uid)
                .collection("private").document("data").getDocumentAsync()
            let main = await mainSnap?.data() ?? [:]
            let priv = await privateSnap?.data() ?? [:]
            guard !Task.isCancelled, let self else { return }
            self.userMood = (priv["selectedMood"] as? String) ?? (main["selectedMood"] as? String)
            // breakupStage is private-only — written by OnboardingView.stageStep
            // and (eventually) editable in Settings. No legacy main-doc
            // fallback because the field never lived there.
            self.userBreakupStage = priv["breakupStage"] as? String

            // Engaged-tag rollup: fetch the last 50 liked posts, then fetch the
            // tag of each in parallel chunks, then REPLACE engagedTags with the
            // fresh count. Never += into the existing dictionary — that
            // accumulated across refreshes and quietly skewed the for-you
            // score boost at line ~514.
            guard let likedSnap = try? await db.collection("users").document(uid).collection("liked")
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .getDocumentsAsync() else { return }
            guard !Task.isCancelled else { return }

            let postIds = likedSnap.documents.map { $0.documentID }
            guard !postIds.isEmpty else {
                self.engagedTags = [:]
                return
            }
            let chunks = stride(from: 0, to: postIds.count, by: 30).map {
                Array(postIds[$0..<min($0 + 30, postIds.count)])
            }

            var newTags: [String: Int] = [:]
            await withTaskGroup(of: [String].self) { group in
                for chunk in chunks {
                    group.addTask {
                        guard !Task.isCancelled else { return [] }
                        guard let postSnap = try? await db.collection("posts")
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocumentsAsync() else { return [] }
                        return postSnap.documents.compactMap { $0.data()["tag"] as? String }
                    }
                }
                for await tags in group {
                    for tag in tags {
                        newTags[tag, default: 0] += 1
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.engagedTags = newTags
        }
    }

    // MARK: - Filter Helper

    nonisolated func filterBlocked(documents: [QueryDocumentSnapshot]) -> [QueryDocumentSnapshot] {
        return documents.filter { doc in
            let data = doc.data()
            let authorId = data["authorId"] as? String ?? ""
            if BlockedUsersCache.shared.isBlocked(authorId) { return false }
            if let originalAuthorId = data["originalAuthorId"] as? String,
               BlockedUsersCache.shared.isBlocked(originalAuthorId) { return false }
            if let expiresAt = data["expiresAt"] as? Timestamp,
               expiresAt.dateValue() < Date() { return false }
            // Hide posts flagged by server-side moderation (Cloud Functions)
            if data["flagged"] as? Bool == true { return false }
            return true
        }
    }

    // MARK: - Extract extra post metadata

    /// Soft cap to prevent unbounded growth across long sessions. Once a per-
    /// post metadata cache exceeds this size, we drop a random ~20% of entries.
    /// Random drop avoids the scan cost of LRU tracking while still bounding
    /// memory; cache misses just re-extract from the next snapshot pass.
    private static let postMetadataSoftCap = 800

    func extractPostMetadata(from doc: QueryDocumentSnapshot) {
        let docData = doc.data()
        if let gifUrl = docData["gifUrl"] as? String {
            postGifUrls[doc.documentID] = gifUrl
        }
        if docData["isMidnightPost"] as? Bool == true {
            midnightPostIds.insert(doc.documentID)
        }
        if docData["isLetter"] as? Bool == true {
            letterPostIds.insert(doc.documentID)
        }
        if docData["isRepost"] as? Bool == true {
            repostPostIds.insert(doc.documentID)
        }
        if docData["isWhisper"] as? Bool == true {
            whisperPostIds.insert(doc.documentID)
        }
        // Trim if any of the metadata stores have grown past the cap. Cheap
        // count check; the actual trim only runs occasionally.
        if postGifUrls.count > Self.postMetadataSoftCap
            || midnightPostIds.count > Self.postMetadataSoftCap
            || letterPostIds.count > Self.postMetadataSoftCap
            || repostPostIds.count > Self.postMetadataSoftCap
            || whisperPostIds.count > Self.postMetadataSoftCap {
            trimPostMetadata()
        }
    }

    private func trimPostMetadata() {
        // Keep metadata for any post that is currently visible in either the
        // For You feed or the Following feed. Using only `posts` here would
        // drop metadata for Following-tab-only posts the moment this runs.
        var keepIds = Set(posts.map { $0.id })
        keepIds.formUnion(followingPosts.map { $0.id })
        postGifUrls = postGifUrls.filter { keepIds.contains($0.key) }
        midnightPostIds = midnightPostIds.intersection(keepIds)
        letterPostIds = letterPostIds.intersection(keepIds)
        repostPostIds = repostPostIds.intersection(keepIds)
        whisperPostIds = whisperPostIds.intersection(keepIds)
        // Prune the expanded-letter set too — it's only ever inserted into, so
        // without this it grew unbounded across a session and kept stale ids alive.
        expandedLetterIds = expandedLetterIds.intersection(keepIds)
    }

    // MARK: - Fetch Posts

    func fetchPosts() {
            guard Auth.auth().currentUser != nil else {
                print("⚠️ fetchPosts — skipped, currentUser is nil at call time")
                return
            }
            // Coalesce concurrent callers. Without this, every rapid onAppear /
            // notification trigger fires a fresh 60-doc Firestore query in parallel,
            // wasting reads and racing on posts assignment.
            guard !isFetchingPosts else {
                print("⚠️ fetchPosts — already in flight, skipping")
                return
            }
            isFetchingPosts = true
            // Reset the blocking-saturation flag here too, not just inside
            // loadMorePosts. Without this, a refresh that lands on a clean
            // batch never clears the stale flag set by a prior pagination
            // session, and the UI can incorrectly show end-of-feed copy.
            endedDueToBlocking = false
            let db = Firestore.firestore()
            print("🔄 fetchPosts — firing Firestore query, hasAuth: \(Auth.auth().currentUser != nil)")

            Task { @MainActor in
                defer { self.isFetchingPosts = false }
                // moderationStatus filter required by firestore.rules
                // 2026-05-31: pending-review posts are hidden from non-author
                // readers, so the query must pin moderationStatus=="live" or
                // the rule layer denies the entire list operation. Author can
                // still see their own pending posts via ProfileView (which
                // filters by authorId == self, so isOwner allows the read).
                guard let snapshot = try? await db.collection("posts")
                    .whereField("moderationStatus", isEqualTo: "live")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 60)
                    .getDocumentsAsync() else {
                    self.hasLoadedOnce = true
                    self.posts = []
                    return
                }
                self.fetchError = nil
                let documents = snapshot.documents
                print("✅ fetchPosts — got \(documents.count) docs from Firestore")
                let filtered = self.filterBlocked(documents: documents)

                    let scored: [(doc: QueryDocumentSnapshot, score: Double)] = filtered.map { doc in
                        let data = doc.data()
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        let likeCount = data["likeCount"] as? Int ?? 0
                        let replyCount = data["replyCount"] as? Int ?? 0
                        let tag = data["tag"] as? String

                        var score: Double = 0

                                                let hoursAgo = Date().timeIntervalSince(createdAt) / 3600
                                                if hoursAgo < 1 { score += 50 }
                                                else if hoursAgo < 3 { score += 40 }
                                                else if hoursAgo < 6 { score += 30 }
                                                else if hoursAgo < 12 { score += 20 }
                                                else if hoursAgo < 24 { score += 10 }
                                                else { score += max(0, 5 - hoursAgo / 24) }

                                                // Stage-aware time-decay floor. Default is 0.2 — older posts
                                                // bottom out at 20% of fresh-engagement signal, which suits
                                                // fresh-breakup users who want recent feeling. Users further out
                                                // (months / a year+) want reflective posts that aged well to keep
                                                // surfacing, so we raise the floor for them — older highly-engaged
                                                // posts retain more of their score and float up vs the default.
                                                // "still in it" stays on the fresh-floor since they're effectively
                                                // pre-breakup — the live moment matters more than the archive.
                                                // Read stage from UserHandleCache first; fall back to the
                                                // VM-local copy. The cache listener boots earlier than
                                                // fetchUserPreferences so a fresh feed load gets the right
                                                // floor on the first scoring pass instead of the second.
                                                let stageForFloor = UserHandleCache.shared.breakupStage ?? self.userBreakupStage
                                                let decayFloor: Double
                                                switch stageForFloor {
                                                case "a year or more": decayFloor = 0.6
                                                case "months in":      decayFloor = 0.45
                                                case "they left", "i left":
                                                    decayFloor = 0.35
                                                default:               decayFloor = 0.2
                                                }
                                                let decayFactor = max(decayFloor, 1.0 - (hoursAgo / 48.0))
                                                score += Double(likeCount) * 1.5 * decayFactor
                                                score += Double(replyCount) * 2.0 * decayFactor

                        if let tag = tag, let mood = self.userMood, tag == mood {
                            score += 15
                        }

                        if let tag = tag, let tagCount = self.engagedTags[tag] {
                            score += Double(tagCount) * 5
                        }

                        if tag != nil { score += 3 }
                        if data["isLetter"] as? Bool == true { score += 5 }

                        var hasher = Hasher()
                        hasher.combine(doc.documentID)
                        hasher.combine(Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0)
                        let hash = abs(hasher.finalize())
                        score += Double(hash % 500) / 100.0

                        return (doc: doc, score: score)
                    }

                    let ranked = scored.sorted { $0.score > $1.score }
                    let topDocs = Array(ranked.prefix(20))

                    var newPosts: [FeedPost] = []
                    for item in topDocs {
                        newPosts.append(FeedView.feedPost(from: item.doc))
                        self.extractPostMetadata(from: item.doc)
                    }

                print("✅ fetchPosts — setting \(newPosts.count) posts after scoring/filtering")

                if !newPosts.isEmpty {
                                                                                                                            self.posts = newPosts
                                                                                                                            self.hasLoadedOnce = true
                                                                                                                            // Cursor must track Firestore's query order (createdAt DESC),
                                                                                                                            // not our client-side score rank. Using topDocs.last previously
                                                                                                                            // set the cursor to the lowest-scored doc in the top-20 — and
                                                                                                                            // `start(afterDocument:)` then resumed in createdAt order after
                                                                                                                            // that doc, silently skipping the chronologically-earlier posts
                                                                                                                            // that ranked below the top-20 on this page. Net effect was
                                                                                                                            // permanent holes in the feed.
                                                                                                                            self.lastDocument = documents.last
                                                                                                                            self.hasMorePosts = documents.count >= 60
                                                                                        } else if documents.count >= 60 {
                                                                                                                                                    self.hasLoadedOnce = true
                                                                                                                                                    self.posts = []
                                                                                                                                                    self.lastDocument = documents.last
                                                                                                                                                    self.hasMorePosts = true
                                                                                                                                                    self.loadMorePosts()
                                                                                                                                                } else {
                                                                                                                                                    self.hasLoadedOnce = true
                                                                                                                                                    self.posts = []
                                                                                                                                                    self.hasMorePosts = false
                                                                                                                                                }
            }
                }

                // MARK: - Load More Posts

    func loadMorePosts(depth: Int = 0) {
        guard !isLoadingMore, hasMorePosts, let last = lastDocument else { return }
        guard depth < 5 else {
            isLoadingMore = false
            hasMorePosts = false
            endedDueToBlocking = true
            return
        }
        isLoadingMore = true

        let db = Firestore.firestore()
        db.collection("posts")
                    // moderationStatus filter required by firestore.rules
                    // (see fetchPosts comment).
                    .whereField("moderationStatus", isEqualTo: "live")
                    .order(by: "createdAt", descending: true)
                    .start(afterDocument: last)
                    .limit(to: 20)
                    .getDocuments { [weak self] snapshot, error in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                    if let error = error {
                        print("⚠️ loadMorePosts error: \(error)")
                        self.isLoadingMore = false
                        self.fetchError = "couldn't load more posts — pull to retry"
                        return
                    }
                    self.fetchError = nil
                    guard let documents = snapshot?.documents else {
                        self.isLoadingMore = false
                        self.hasMorePosts = false
                        return
                    }
                    let filtered = self.filterBlocked(documents: documents)
                    var existingIds = Set(self.posts.map { $0.id })
                    for doc in filtered where !existingIds.contains(doc.documentID) {
                        existingIds.insert(doc.documentID)
                        self.posts.append(FeedView.feedPost(from: doc))
                        self.extractPostMetadata(from: doc)
                    }
                    self.lastDocument = documents.last
                    self.hasMorePosts = documents.count >= 20
                    self.endedDueToBlocking = false
                    if filtered.isEmpty && documents.count >= 20 {
                        self.isLoadingMore = false
                        self.loadMorePosts(depth: depth + 1)
                    } else {
                        self.isLoadingMore = false
                    }
                }
            }
    }

    // MARK: - Following Posts

    private var followingTask: Task<Void, Never>? = nil

    func fetchFollowingPosts() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let db = Firestore.firestore()

            followingTask?.cancel()
            followingTask = Task { @MainActor in
                let followingLimit = 200
                guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
                guard let followSnap = try? await db.collection("users").document(uid).collection("following")
                    .limit(to: followingLimit)
                    .getDocumentsAsync() else {
                    self.fetchError = "couldn't load following posts — pull to retry"
                    return
                }

                let followedIds = followSnap.documents.map { $0.documentID }
                guard !followedIds.isEmpty else {
                    followingPosts = []
                    followingFetchIncomplete = false
                    return
                }

                if followSnap.documents.count >= followingLimit {
                    followingFetchIncomplete = true
                }

                let chunks = stride(from: 0, to: followedIds.count, by: 30).map {
                    Array(followedIds[$0..<min($0 + 30, followedIds.count)])
                }

                // FIX: task group closures are non-isolated, so @MainActor methods
                // like FeedView.feedPost(from:) cannot be called inside them.
                // Instead, collect raw documents from each chunk and do all
                // @MainActor parsing after the group completes on the main actor.
                var allRawResults: [(doc: QueryDocumentSnapshot, date: Date)] = []
                var anyChunkFailed = false

                await withTaskGroup(of: [(doc: QueryDocumentSnapshot, date: Date)]?.self) { group in
                    for chunk in chunks {
                        group.addTask {
                            // This closure is non-isolated — only pure Swift and
                            // non-actor-isolated calls are allowed here.
                            guard let postSnapshot = try? await db.collection("posts")
                                // moderationStatus filter required by firestore.rules
                                // (see fetchPosts comment). Following-feed queries OTHER
                                // users' posts, so the isOwner branch doesn't help here.
                                .whereField("moderationStatus", isEqualTo: "live")
                                .whereField("authorId", in: chunk)
                                // No recency window. A 3-day `createdAt` filter used to
                                // live here, but it left the following feed EMPTY whenever
                                // a followed user hadn't posted in the last 3 days — the
                                // norm in a low-frequency app, so following someone who'd
                                // posted earlier showed nothing. Now we show their most
                                // recent posts regardless of age. Served by the existing
                                // posts(moderationStatus, authorId, createdAt DESC) index.
                                .order(by: "createdAt", descending: true)
                                .limit(to: 30)
                                .getDocumentsAsync() else { return nil }

                            // filterBlocked is now nonisolated so it's safe here.
                            let filtered = self.filterBlocked(documents: postSnapshot.documents)
                            return filtered.map { doc in
                                let createdAt = (doc.data()["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                                return (doc: doc, date: createdAt)
                            }
                        }
                    }

                    for await chunkResults in group {
                        if let results = chunkResults {
                            allRawResults.append(contentsOf: results)
                        } else {
                            anyChunkFailed = true
                        }
                    }
                }

                // Back on the main actor — safe to call FeedView.feedPost(from:)
                // and extractPostMetadata here.
                guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
                let sorted = allRawResults.sorted { $0.date > $1.date }.prefix(50)
                followingPosts = sorted.map { item in
                    let post = FeedView.feedPost(from: item.doc)
                    self.extractPostMetadata(from: item.doc)
                    return post
                }
                let wasTruncated = followSnap.documents.count >= followingLimit
                followingFetchIncomplete = anyChunkFailed || wasTruncated
            }
        }

    // MARK: - Witness Post

    func fetchWitnessPost() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        db.collection("posts")
            // moderationStatus filter required by firestore.rules
            // (see fetchPosts comment).
            .whereField("moderationStatus", isEqualTo: "live")
            .whereField("replyCount", isEqualTo: 0)
            .whereField("isRepost", isEqualTo: false)
            .order(by: "createdAt", descending: true)
            .limit(to: 10)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("⚠️ fetchWitnessPost — check composite index (replyCount, isRepost, createdAt): \(error)")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let documents = snapshot?.documents else { return }
                    guard let doc = documents.first(where: {
                        let data = $0.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if authorId == uid || BlockedUsersCache.shared.isBlocked(authorId) { return false }
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                        if data["flagged"] as? Bool == true { return false }
                        return true
                    }) else { return }
                    let data = doc.data()
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    self.witnessPost = WitnessPostData(
                        postId: doc.documentID,
                        handle: data["authorHandle"] as? String ?? "anonymous",
                        text: data["text"] as? String ?? "",
                        tag: data["tag"] as? String,
                        timeString: ToskaFormatters.hourMinute.string(from: createdAt).lowercased(),
                        likeCount: data["likeCount"] as? Int ?? 0,
                        repostCount: data["repostCount"] as? Int ?? 0
                    )
                }
            }
    }

    // MARK: - Most Unsaid Today

    func fetchMostUnsaidAndDailyMoment() {
        guard Auth.auth().currentUser != nil else { return }
        let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
        Firestore.firestore().collection("posts")
            // moderationStatus filter required by firestore.rules
            // (see fetchPosts comment).
            .whereField("moderationStatus", isEqualTo: "live")
            .whereField("createdAt", isGreaterThan: Timestamp(date: yesterday))
            .whereField("isRepost", isEqualTo: false)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        print("⚠️ fetchMostUnsaidAndDailyMoment error: \(error)")
                        return
                    }
                    guard let docs = snapshot?.documents else {
                        self.mostUnsaidText = ""
                        self.mostUnsaidLikes = 0
                        self.mostUnsaidPostId = ""
                        self.hasDailyMoment = false
                        return
                    }
                    let sorted = docs.sorted {
                        ($0.data()["likeCount"] as? Int ?? 0) > ($1.data()["likeCount"] as? Int ?? 0)
                    }

                    if let topDoc = sorted.first {
                        self.hasDailyMoment = (topDoc.data()["likeCount"] as? Int ?? 0) > 0
                    } else {
                        self.hasDailyMoment = false
                    }

                    guard let doc = sorted.first(where: {
                        let data = $0.data()
                        if BlockedUsersCache.shared.isBlocked(data["authorId"] as? String ?? "") { return false }
                        if let expiresAt = data["expiresAt"] as? Timestamp, expiresAt.dateValue() < Date() { return false }
                        if data["flagged"] as? Bool == true { return false }
                        return true
                    }) else {
                        self.mostUnsaidText = ""
                        self.mostUnsaidLikes = 0
                        self.mostUnsaidPostId = ""
                        return
                    }
                    let data = doc.data()
                    self.mostUnsaidText = data["text"] as? String ?? ""
                    self.mostUnsaidLikes = data["likeCount"] as? Int ?? 0
                    self.mostUnsaidPostId = doc.documentID
                }
            }
    }

    // MARK: - Anniversary Post

    func fetchAnniversaryPost() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // "still in it" users haven't had a breakup yet — anniversaries
        // are nonsensical for them. Skip the whole fetch. nil and any
        // other stage value still walks the full milestone ladder.
        //
        // Read from UserHandleCache rather than self.userBreakupStage:
        // refreshAll() and loadInitialData both call this on the same
        // tick they call fetchUserPreferences, so self.userBreakupStage
        // is racy on first load. The cache listener boots from
        // AppDelegate's auth-state listener (toskaApp.swift), so it has
        // a head start and is populated by the time the feed is ready.
        let stage = UserHandleCache.shared.breakupStage ?? userBreakupStage
        if stage == "still in it" {
            anniversaryPost = nil
            return
        }
        let db = Firestore.firestore()
        let now = Date()
        let cal = Calendar.current

        // Milestones walked in priority order — most-meaningful first.
        // First window with a non-flagged post wins; the others are skipped.
        // Window is 24h centered on the milestone date so a post written
        // anytime that day surfaces. Same composite index requirement as
        // before (authorId, isRepost, createdAt).
        struct Milestone {
            let component: Calendar.Component
            let value: Int
            let label: String
        }
        let milestones: [Milestone] = [
            Milestone(component: .year,  value: -1, label: "a year into it"),
            Milestone(component: .month, value: -6, label: "six months in"),
            Milestone(component: .month, value: -3, label: "three months in"),
            Milestone(component: .month, value: -1, label: "a month in"),
        ]

        Task { @MainActor in
            for m in milestones {
                guard let target = cal.date(byAdding: m.component, value: m.value, to: now) else { continue }
                let start = target.addingTimeInterval(-12 * 60 * 60)
                let end = target.addingTimeInterval(12 * 60 * 60)

                let snap: QuerySnapshot?
                do {
                    snap = try await db.collection("posts")
                        .whereField("authorId", isEqualTo: uid)
                        .whereField("isRepost", isEqualTo: false)
                        .whereField("createdAt", isGreaterThan: Timestamp(date: start))
                        .whereField("createdAt", isLessThan: Timestamp(date: end))
                        .limit(to: 1)
                        .getDocumentsAsync()
                } catch {
                    print("⚠️ fetchAnniversaryPost(\(m.label)) — check composite index (authorId, isRepost, createdAt): \(error)")
                    continue
                }
                // Captured-uid recheck. The query filter is `authorId == uid`,
                // so a sign-out/sign-in race during the fetch would otherwise
                // land the previous user's milestone post text into the new
                // user's UI under the milestone label — a misattribution that
                // exposes prior-account authorship.
                guard Auth.auth().currentUser?.uid == uid else { return }
                guard let doc = snap?.documents.first else { continue }
                let data = doc.data()
                // Don't surface a milestone post that was later flagged by
                // moderation — see fetchAnniversaryPost original-version
                // rationale. Skip + continue so an older milestone window
                // can still match if this one's hit was flagged.
                if data["flagged"] as? Bool == true { continue }
                if data["concerningContent"] as? Bool == true { continue }
                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                self.anniversaryPost = AnniversaryPostData(
                    postId: doc.documentID,
                    text: data["text"] as? String ?? "",
                    tag: data["tag"] as? String,
                    dateString: ToskaFormatters.fullDate.string(from: createdAt).lowercased(),
                    milestoneLabel: m.label
                )
                return
            }
            // No milestone matched — clear any stale prior value so a card
            // from yesterday's session doesn't linger after the post was
            // deleted or its window passed.
            self.anniversaryPost = nil
        }
    }

    // MARK: - Emotional Weather

    func fetchEmotionalWeather() {
        guard Auth.auth().currentUser != nil else { return }
        let db = Firestore.firestore()
        let sixHoursAgo = Date().addingTimeInterval(-6 * 60 * 60)

        db.collection("posts")
            // moderationStatus filter required by firestore.rules
            // (see fetchPosts comment).
            .whereField("moderationStatus", isEqualTo: "live")
            .whereField("createdAt", isGreaterThan: Timestamp(date: sixHoursAgo))
            .limit(to: 50)
            .getDocuments { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        print("⚠️ fetchEmotionalWeather error: \(error)")
                        self.setDefaultWeather()
                        return
                    }
                    guard let documents = snapshot?.documents else {
                        self.setDefaultWeather()
                        return
                    }
                    // Filter out posts authored by users the viewer has blocked.
                    // Without this, a blocked user's tag selections still
                    // shape the aggregate "today's weather" message — the
                    // viewer keeps seeing emotional cues from someone they
                    // explicitly cut off. This is the same client-side
                    // pattern the feed itself uses.
                    var tagCounts: [String: Int] = [:]
                    for doc in documents {
                        let data = doc.data()
                        let authorId = data["authorId"] as? String ?? ""
                        if !authorId.isEmpty, BlockedUsersCache.shared.isBlocked(authorId) {
                            continue
                        }
                        if let tag = data["tag"] as? String {
                            tagCounts[tag, default: 0] += 1
                        }
                    }
                    if let topTag = tagCounts.max(by: { $0.value < $1.value }) {
                        self.weatherTag = topTag.key
                        self.emotionalWeather = self.weatherPhrase(for: topTag.key)
                    } else {
                        self.setDefaultWeather()
                    }
                }
            }
    }

    // MARK: - Share Most Unsaid

    func shareMostUnsaid() {
        guard !mostUnsaidText.isEmpty else { return }

        let cardView = ZStack {
                    Color.toskaNearBlack

                    VStack(spacing: 0) {
                        Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.toskaBlue)
                        .frame(width: 4, height: 4)
                    Text("most unsaid today")
                        .font(ToskaFont.sans(11, weight: .semibold))
                        .foregroundColor(Color.toskaBlue)
                        .tracking(1)
                }
                .padding(.bottom, 24)

                Text(mostUnsaidText)
                    .font(.custom("Georgia", size: 22))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                Text("\(formatCount(mostUnsaidLikes)) felt this")
                    .font(ToskaFont.sans(13, weight: .medium))
                    .foregroundColor(Color.toskaWhisperPink.opacity(0.7))
                    .padding(.bottom, 24)

                VStack(spacing: 4) {
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 18))
                        .foregroundColor(.white.opacity(0.15))
                    Text("say what you never said")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(.white.opacity(0.08))
                }
                .padding(.bottom, 40)
            }
        }
        .frame(width: 1080 / 3, height: 1920 / 3)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0

        if let image = renderer.uiImage {
            presentShareSheet(with: [image])
        }
    }

    // MARK: - Weather Helpers

    func setDefaultWeather() {
        let defaults: [(String, String)] = [
                    ("longing", "a lot of people are missing someone right now"),
                    ("regret", "everyone keeps thinking about what they shouldve said"),
                    ("still love you", "a lot of people still love someone who left"),
                ]
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let pick = defaults[dayOfYear % defaults.count]
        weatherTag = pick.0
        emotionalWeather = pick.1
    }

    func weatherPhrase(for tag: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        if hour >= 21 || hour < 5 { timeOfDay = "tonight" }
        else if hour < 12 { timeOfDay = "this morning" }
        else if hour < 17 { timeOfDay = "this afternoon" }
        else { timeOfDay = "this evening" }

        switch tag {
                case "longing": return "a lot of people are missing someone \(timeOfDay)"
                case "anger": return "a lot of people are angry \(timeOfDay)"
                case "regret": return "everyone keeps replaying the same moments \(timeOfDay)"
                case "acceptance": return "people are trying to accept things \(timeOfDay)"
                case "confusion": return "nobody knows what theyre feeling \(timeOfDay)"
                case "unsent": return "a lot of things are going unsaid \(timeOfDay)"
                case "moving on": return "people are trying to move on \(timeOfDay)"
                case "still love you": return "a lot of people still love someone they shouldnt \(timeOfDay)"
                default: return "everyones going through something \(timeOfDay)"
                }
    }
}
