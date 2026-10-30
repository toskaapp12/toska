// Server-side mirror of toska/FeedView.swift::containsNameOrIdentifyingInfo.
//
// Why this exists separately from the JS containsPII() helper inside
// functions/index.js: the iOS pre-publish detector grew a much larger
// surface area in the 2026-05-01 pre-launch sprint (confusable folding,
// leet, separator collapse, last names, dotted initials, apartment numbers)
// and a tampered client that bypasses the iOS check would otherwise slip
// straight through to feed. This module ports the full Swift detector so
// the server can reject the same inputs the iOS app rejects, and is wired
// into validatePost / validateReply in index.js for create-time enforcement.
// containsPII() in index.js also delegates here so the post-update / reply-
// update / DM moderation triggers benefit from the same coverage.
//
// Keep this file in sync with toska/FeedView.swift::containsNameOrIdentifyingInfo
// when adding new evasion vectors. The test suite at
// firestore-tests/moderation.test.js pins both the regression set (all
// original Swift cases still flag) and the new evasion cases.

// ============================================================
// Constants — mirror the Swift sets verbatim so behavior is identical.
// ============================================================

// Given names (2026-10-29 expansion, owner decision): the original hand list ∪ the top ~4,000 Latin-script
// given-name items from Wikidata (CC0, sitelinks ≥ 4, ranked by sitelink count; retrieved 2026-10-29) — spans
// English, Spanish/Portuguese, South Asian, romanized East Asian, Arabic, Turkish, African and Slavic names.
// Mirror: ContentModeration.swift commonNames (detector-parity pins both).
const COMMON_NAMES = new Set([
  "a'isha", "aad", "aadu", "aage", "aagje", "aagot", "aake", "aaliyah", "aapo", "aare", "aarni", "aaron",
  "aart", "aase", "aatos", "aavo", "aba", "abbas", "abby", "abdallah", "abderrahim", "abdi", "abdon", "abdoulaye",
  "abdu", "abdul", "abdullah", "abe", "abeer", "abel", "abigail", "abraham", "absalom", "abu'l-fadl", "acacio", "achille",
  "achilles", "acyuta", "ada", "adalbert", "adalberto", "adam", "adan", "addison", "adela", "adelaida", "adelaide", "adele",
  "adelheid", "adelina", "adem", "ademar", "adib", "adil", "adina", "admir", "adnan", "adolf", "adolfina", "adolfo",
  "adolph", "adolphe", "adolphus", "adrian", "adriana", "adriano", "adrienne", "adwoa", "aegidius", "afanasy", "afonso", "afra",
  "afshin", "agata", "agatha", "agathe", "agaton", "age", "agim", "aglaia", "agnar", "agne", "agnes", "agnese",
  "agneta", "agnete", "agneya", "agnieszka", "agota", "agrippina", "agustin", "ahinoam", "ahmad", "ahmed", "ahmet", "aida",
  "aidan", "aiden", "aija", "aiko", "aila", "aileen", "aili", "aimar", "aime", "aimee", "aina", "ainhoa",
  "aino", "airi", "aisling", "aitor", "aivar", "aivaras", "aivars", "ajay", "ajda", "ake", "akemi", "aki",
  "akif", "akihiko", "akihito", "akio", "akira", "akos", "akosua", "akram", "akseli", "akua", "alaa", "aladar",
  "aladdin", "alain", "alajos", "alan", "alana", "alasdair", "alba", "alban", "albert", "alberta", "albertas", "albertina",
  "alberto", "albin", "albina", "albino", "albrecht", "alcide", "alda", "aldo", "aldona", "alejandra", "alejandro", "aleks",
  "aleksa", "aleksandar", "aleksander", "aleksandr", "aleksandra", "aleksandras", "aleksanteri", "aleksej", "aleksey", "aleksi", "alen", "alena",
  "alenka", "ales", "alessandra", "alessandro", "alessia", "alessio", "aletta", "alex", "alexa", "alexander", "alexandr", "alexandra",
  "alexandre", "alexandrine", "alexandru", "alexej", "alexia", "alexis", "alexius", "alf", "alfhild", "alfons", "alfonso", "alfonz",
  "alfred", "alfreda", "alfredo", "algernon", "algirdas", "algis", "algot", "ali", "alice", "alicia", "alida", "alim",
  "alina", "alisha", "alison", "alissa", "alistair", "alix", "aljosa", "alla", "allan", "allie", "alma", "almudena",
  "alois", "aloisia", "aloisio", "alojz", "alojzy", "aloys", "aloysius", "alper", "althea", "alva", "alvar", "alvaro",
  "alvhild", "alvin", "alvina", "alvise", "alwin", "alyona", "alyssa", "amadea", "amadeus", "amaia", "amal", "amalia",
  "amalie", "amalric", "amanda", "amandine", "amandus", "amane", "amaya", "amber", "ambrosius", "ambrozy", "ambrus", "amelia",
  "amelie", "amenhotep", "amer", "amilcar", "amina", "aminata", "aminu", "amir", "amira", "ammavaru", "amos", "amparo",
  "amr", "amund", "amy", "ana", "anabela", "anabella", "anacleto", "anais", "anas", "anastasia", "anastasius", "anastasiya",
  "anatol", "anatoly", "ander", "anders", "anderson", "andi", "andoni", "andor", "andras", "andraz", "andre", "andrea",
  "andreas", "andree", "andrei", "andrej", "andrejs", "andres", "andrew", "andrey", "andri", "andrijana", "andris", "andrius",
  "andriy", "andrus", "andrzej", "andy", "aneta", "anete", "anett", "anette", "angel", "angela", "angele", "angelika",
  "angelina", "angelique", "angelo", "angie", "angus", "ani", "anica", "anika", "anis", "anisa", "anissa", "anita",
  "anitra", "anja", "anka", "anke", "ankit", "ann", "anna", "annabel", "annabeth", "annalena", "annalisa", "anne",
  "annegret", "anneli", "annelie", "anneliese", "annemarie", "annette", "anni", "annibale", "annie", "annika", "anniken", "annikki",
  "anny", "anouar", "anouk", "anri", "ansgar", "anssi", "antal", "antanas", "ante", "antero", "anthony", "anto",
  "antoine", "antoinette", "anton", "antonella", "antoni", "antonia", "antonietta", "antonija", "antonije", "antonin", "antonina", "antonino",
  "antonio", "ants", "antti", "antun", "anu", "anwar", "anya", "aodh", "aoife", "apollo", "apollonia", "arabella",
  "araceli", "aram", "aranka", "arantxa", "arash", "arben", "are", "ari", "aria", "ariadna", "ariadne", "ariana",
  "arianna", "aribert", "ariel", "arif", "arild", "arina", "ariobarzanes", "arja", "arkadiusz", "arkady", "arlene", "arlette",
  "armand", "armanda", "armando", "armel", "armin", "arna", "arnaldo", "arnar", "arne", "arnfinn", "arnold", "arnost",
  "arnulf", "arnulfo", "aron", "arpad", "arsaces", "arsene", "arsenije", "arsenius", "arslan", "art", "artaxerxes", "artem",
  "artemon", "arthur", "arttu", "artturi", "artur", "arturo", "arturs", "artyom", "arun", "arve", "arved", "arvid",
  "arvo", "arvydas", "arya", "arzu", "asa", "asaf", "ase", "asgeir", "asger", "ashkbous", "ashley", "ashraf",
  "asim", "asko", "aslak", "aslaug", "asma", "asmund", "asmundur", "assar", "asta", "astika", "aston", "astrid",
  "asuman", "asuncion", "atanas", "atanasije", "athanasios", "athanasius", "atle", "atsushi", "attila", "aud", "audrey", "audrius",
  "audun", "augusta", "augustina", "augustinus", "augusto", "augustus", "auke", "aulis", "aura", "aurel", "aurelia", "aurelie",
  "aurelien", "aurora", "aurore", "ausra", "ava", "avelina", "avery", "avgust", "avtandil", "axel", "aya", "ayaka",
  "ayako", "aydan", "aykut", "ayla", "aylin", "aymen", "ayse", "aysel", "ayumi", "ayyub", "azamat", "aziz",
  "aziza", "azra", "babak", "babasaheb", "badr", "bahar", "bakasura", "balbina", "baldomero", "balduin", "baldur", "baltasar",
  "baltazar", "balthazar", "barack", "barak", "barbara", "barbora", "barbro", "barnaba", "barnabas", "barney", "barnim", "barry",
  "bart", "bartholomaus", "bartholomew", "bartolomeo", "bartolomeu", "bartosz", "baruch", "bashar", "bashir", "basil", "basilius", "bastian",
  "bea", "beata", "beate", "beatrice", "beatrix", "beatriz", "becky", "beda", "bedrich", "begona", "behrouz", "bekir",
  "bela", "belinda", "bella", "ben", "benat", "bence", "benedetto", "benedict", "benedictus", "benedikt", "benedikte", "benedykt",
  "bengt", "bengta", "benigna", "benita", "benito", "benjamin", "benno", "benny", "beno", "bent", "bente", "beppe",
  "berend", "berengar", "berengere", "berenice", "berit", "bernadette", "bernard", "bernarda", "bernardina", "bernardo", "bernd", "bernhard",
  "bernt", "bert", "berta", "bertalan", "bertel", "bertha", "berthold", "bertil", "bertold", "bertram", "bertrand", "beryl",
  "beth", "bethany", "bettina", "betty", "beverly", "bhutamata", "biagio", "bianca", "bianka", "bilal", "biljana", "bill",
  "billy", "birger", "birgit", "birgitta", "birgitte", "birte", "bjarke", "bjarne", "bjarni", "bjarte", "bjorn", "blagoje",
  "blaise", "blake", "blanca", "blanka", "blas", "blasius", "bob", "bobby", "bodhmall", "bodil", "bodo", "bodog",
  "bogdan", "bogdana", "boglarka", "bogoljub", "bogomir", "bogumil", "bohumil", "bohumila", "bohumir", "bohuslav", "bojan", "bojana",
  "boldizsar", "boleslav", "bonaventura", "bonifatius", "bonnie", "bora", "borghild", "boris", "borislav", "borja", "borje", "borut",
  "botvid", "boyan", "boye", "bozena", "bozidar", "brad", "bradley", "brady", "brahmani", "brandon", "branimir", "branislav",
  "branislava", "brankica", "branko", "bratislav", "braulio", "brenda", "brendan", "brent", "brett", "brian", "brianna", "bridget",
  "brigita", "brigitta", "brigitte", "brita", "britt", "britta", "brittany", "bronislav", "bronislava", "brooke", "bror", "bruce",
  "bruna", "bruno", "bryan", "brynjar", "bulent", "burak", "burkhard", "buster", "cagla", "caitlin", "caleb", "calum",
  "calvin", "cameron", "camilla", "camille", "candace", "candida", "candido", "cansu", "carina", "carl", "carla", "carles",
  "carlo", "carlos", "carman", "carmelo", "carmen", "carmine", "carol", "carola", "carolina", "caroline", "carolyn", "carsten",
  "casey", "casper", "cassandra", "catarina", "caterina", "cathal", "catharina", "catherine", "cathy", "cato", "cecile", "cecilia",
  "cecilie", "cecylia", "cedric", "celeste", "celia", "celina", "celine", "celso", "cem", "cesar", "cethlenn", "cetin",
  "cezary", "chad", "chaim", "chandler", "chandra", "chantal", "charalampos", "charlene", "charles", "charlie", "charlotta", "charlotte",
  "chelamma", "chelsea", "cheryl", "cheyenne", "chiara", "chingiz", "chlodwig", "chloe", "chris", "christa", "christel", "christer",
  "christiaan", "christian", "christiane", "christina", "christine", "christoffer", "christoph", "christopher", "chuck", "ciara", "ciaran", "cigdem",
  "cindy", "cinzia", "ciprian", "cipriano", "ciriaco", "ciro", "claes", "claire", "clara", "clarice", "claude", "claudia",
  "claudio", "cleber", "clelia", "clement", "clemente", "clementina", "cloe", "clovis", "clyde", "cole", "colin", "colm",
  "colton", "conan", "concetta", "connie", "connor", "constance", "consuelo", "cora", "cordelia", "corentin", "corina", "cormac",
  "cornelia", "cornelis", "corneliu", "cornelius", "corrado", "courtney", "craig", "cristiana", "cristiano", "cristina", "cristobal", "crystal",
  "csaba", "csilla", "cunningham", "cuthbert", "cynthia", "cyril", "cyrus", "dafne", "dafydd", "dag", "dagfinn", "dagmar",
  "dagmara", "dagny", "dagur", "daichi", "daiki", "daisuke", "daisy", "dakota", "dalia", "dalibor", "dalila", "dalton",
  "damian", "damiano", "damien", "damir", "damjan", "damodar", "damon", "dan", "dana", "danica", "daniel", "daniela",
  "daniele", "danielle", "daniil", "danijel", "danilo", "dante", "danuta", "daphne", "dara", "dardan", "daria", "dario",
  "darius", "dariusz", "darja", "darko", "darren", "darryl", "darya", "daud", "david", "davida", "davide", "davor",
  "davorin", "davy", "dawid", "dawn", "dea", "dean", "deanna", "debbie", "debora", "deborah", "debra", "deepak",
  "dejan", "delfina", "delia", "demetria", "demetrio", "demetrios", "demetrius", "denes", "denis", "denisa", "denise", "deniz",
  "dennis", "derek", "derya", "desideria", "desiderius", "desire", "desiree", "devajuti", "devala", "dezider", "dezso", "diana",
  "diane", "diarmaid", "dick", "didrik", "diego", "dietmar", "dilara", "dimitar", "dimitri", "dimitrij", "dinesh", "dino",
  "dirk", "dmitry", "dobromir", "dobroslav", "dolly", "dolores", "domenico", "dominic", "dominik", "dominika", "dominique", "domonkos",
  "don", "donald", "donat", "donata", "donika", "donna", "donnie", "dora", "doreen", "dorian", "dorina", "doris",
  "dorofey", "dorota", "dorotea", "dorothea", "dorotheos", "dorothy", "dorottya", "dorrit", "dorte", "dorthe", "dositheus", "douglas",
  "draga", "dragan", "dragana", "dragica", "dragisa", "drago", "dragoljub", "dragomir", "dragoslav", "dragutin", "drahomir", "drahomira",
  "drazen", "drusilla", "duane", "duncan", "dunja", "dusan", "dusko", "duygu", "dylan", "ebba", "ebbe", "ebenezer",
  "eberhard", "eda", "edda", "eddie", "eden", "eder", "edgar", "edgaras", "edgardo", "edi", "edina", "edit",
  "edita", "edith", "edla", "edmond", "edmund", "edmundo", "edna", "edo", "edoardo", "edouard", "eduard", "eduardo",
  "eduards", "edurne", "edvard", "edvin", "edward", "edwin", "edwina", "edzard", "eerik", "eero", "eeva", "efim",
  "efraim", "egil", "egon", "eija", "eik", "eileen", "eilert", "einar", "eino", "eithne", "eivind", "eivor",
  "ekanamsha", "ekaterina", "ekkehard", "ekrem", "ela", "elaine", "eldar", "eleanor", "eleazar", "elek", "elemer", "elena",
  "eleonora", "eleonore", "elfrida", "elfriede", "eli", "elia", "eliana", "elias", "elida", "elie", "eliel", "eliezer",
  "elif", "elijah", "elimar", "elin", "elina", "eline", "elio", "elis", "elisa", "elisabet", "elisabeth", "elisabetta",
  "elise", "elisha", "eliza", "elizabeth", "elke", "ella", "elle", "ellen", "elli", "ellie", "ellinor", "elma",
  "elmar", "elmer", "elmira", "elmo", "elna", "elodie", "elof", "elon", "els", "elsa", "else", "elsie",
  "elton", "elvin", "elvir", "elvira", "elvis", "elza", "elzbieta", "ema", "emanuel", "emelie", "emi", "emil",
  "emile", "emilia", "emilian", "emilie", "emilija", "emilio", "emily", "emin", "emina", "emine", "emma", "emmanuel",
  "emmanuelle", "emmy", "emre", "enar", "endel", "endre", "eneko", "engelbert", "enguerrand", "enid", "eniko", "enn",
  "enoch", "enok", "enric", "enrico", "enrique", "enver", "enzo", "ephraim", "ercole", "erhard", "eric", "erica",
  "erich", "erik", "erika", "erin", "erion", "erkki", "erland", "erlend", "erling", "erna", "ernest", "ernesta",
  "ernesto", "erni", "erno", "ernst", "eros", "ervin", "erwan", "erwin", "eryk", "erzsebet", "esben", "esbjorn",
  "esdras", "eskil", "esmeralda", "espen", "estanislao", "esteban", "estelle", "ester", "estera", "estevao", "esther", "eszter",
  "ethan", "ethel", "etienne", "etsuko", "etta", "eudoxia", "eufemia", "eugen", "eugene", "eugenia", "eulalia", "eulogio",
  "eusebio", "eva", "evald", "evan", "evangelina", "evangelos", "eve", "evelin", "evelina", "evelyn", "even", "everly",
  "evert", "evgenia", "evi", "evita", "evzen", "ewa", "ewen", "eystein", "eysteinn", "ezechiel", "ezequiel", "fabian",
  "fabio", "fabiola", "fabrice", "fabrizio", "facundo", "fadil", "faina", "faith", "faiz", "famke", "fanni", "fanny",
  "farah", "farhad", "farid", "farooq", "fatih", "fatima", "fatma", "fatmir", "fatoumata", "fausta", "faustus", "fay",
  "federica", "federico", "fedir", "fedor", "fedora", "felice", "feliciano", "felicien", "felicity", "feliks", "felipe", "felix",
  "femi", "femke", "feodor", "feodora", "ferdinand", "ferdinanda", "ferdinando", "ferenc", "fernan", "fernanda", "fernando", "fidel",
  "filibert", "filip", "filipa", "filipe", "filipp", "filippa", "filippo", "filomena", "finley", "finn", "fiona", "fionnuala",
  "fiorella", "flavia", "flavio", "flemming", "fletcher", "fleur", "flidais", "flora", "florence", "florencia", "florent", "florentina",
  "florestan", "florian", "floriana", "florimond", "folke", "fran", "franca", "frances", "francesc", "francesca", "francesco", "francis",
  "francisca", "francisco", "franciscus", "franciska", "franciszek", "franco", "francois", "francoise", "franjo", "frank", "franklin", "frans",
  "frantisek", "franz", "franziska", "fred", "freddy", "frederica", "frederick", "frederico", "frederik", "fredrik", "fredrika", "frej",
  "freja", "freya", "frida", "fridolf", "fridtjof", "friederike", "friedrich", "frigyes", "fritiof", "fritjof", "frits", "fritz",
  "frode", "fruzsina", "fuad", "fulgence", "fulgencio", "fulvio", "fumiaki", "gabor", "gabriel", "gabriela", "gabriella", "gabrielle",
  "gad", "gael", "gaetan", "gaetano", "gaia", "gaius", "gaizka", "gaja", "galeazzo", "galina", "gareth", "garrett",
  "gary", "gaute", "gavin", "gavriil", "gay", "gaylord", "gedeon", "gediminas", "geert", "geir", "gemma", "genesis",
  "genevieve", "gennady", "gennaro", "genoveva", "geoffrey", "georg", "george", "georges", "georgi", "georgia", "georgina", "georgios",
  "georgy", "gerald", "geraldine", "gerard", "gerd", "gerda", "gereon", "gergely", "gerhard", "german", "germana", "germund",
  "gernot", "gerrit", "gert", "gertrud", "gertruda", "gertrude", "gervasio", "geza", "gezim", "ghassan", "gheorghe", "ghislain",
  "ghulam", "giacomo", "giancarlo", "gianfranco", "gianluca", "gianluigi", "gianmarco", "giannis", "gianpiero", "gianpietro", "giedrius", "gil",
  "gilbert", "gilberto", "gilda", "gilles", "gillian", "gina", "gino", "gintare", "gintautas", "gioacchino", "giorgia", "giorgio",
  "giosue", "giovanna", "giovanni", "girolamo", "gisbert", "gisela", "gisle", "gitte", "giulia", "giuliana", "giuliano", "giulio",
  "giuseppe", "giuseppina", "gizem", "gladys", "glauco", "gleb", "glenda", "glenn", "gloria", "goffredo", "gohar", "gojko",
  "gokalp", "gokhan", "gokturk", "gonzalo", "gopal", "goran", "gorazd", "gordon", "gorm", "gosta", "gottfried", "gotthilf",
  "gotthold", "grace", "graeme", "graham", "grainne", "grant", "grazyna", "greg", "greger", "gregor", "gregorio", "gregory",
  "greta", "gretchen", "grete", "gretel", "grethe", "grigory", "grimaldo", "griselda", "gro", "gry", "grzegorz", "guadalupe",
  "gualberto", "guangqi", "gudmund", "gudrun", "guglielmo", "guido", "guilherme", "guillaume", "gulnar", "gulsen", "gunda", "gunder",
  "gunhild", "gunilla", "gunn", "gunnar", "gunnel", "gunther", "gunvor", "gurli", "gus", "gustaf", "gustav", "gustave",
  "gustavo", "gustaw", "guttorm", "guy", "gwen", "gwendolyn", "gwenllian", "gwyneth", "gyatso", "gyda", "gyongyi", "gyorgy",
  "gyozo", "gyula", "haakon", "hadi", "hadrian", "hafsa", "hagop", "haitham", "hakan", "hakon", "halfdan", "halim",
  "halina", "halla", "halldor", "hallgeir", "hallvard", "halvar", "halvard", "halvdan", "halvor", "hamad", "hamid", "hamilcar",
  "hamish", "hampus", "hamza", "hana", "hande", "hanka", "hanna", "hannah", "hanne", "hannele", "hannelore", "hannes",
  "hannibal", "hanno", "hannu", "hans", "harald", "hardy", "harold", "harper", "harri", "harriet", "harry", "hartmut",
  "hartvig", "haruto", "hasan", "hashim", "hassan", "hatice", "hatun", "hauke", "havard", "hayato", "hazel", "heather",
  "hector", "hedda", "hedwig", "hege", "heidi", "heike", "heikki", "heiko", "heimo", "heinar", "heino", "heinrich",
  "heinz", "heitor", "helen", "helena", "helene", "helga", "helge", "hella", "helle", "helmer", "helmi", "helmut",
  "helvi", "hendrik", "hennadiy", "henning", "henny", "henri", "henrietta", "henriette", "henrik", "henrike", "henrique", "henry",
  "henryk", "herbert", "herborg", "heriberto", "herman", "hermann", "hermanus", "hermenegildo", "hermes", "hermina", "hermione", "herta",
  "hertha", "hideaki", "hideo", "hieronim", "hieronymus", "hilarius", "hilary", "hilda", "hilde", "hildegard", "hilding", "hildur",
  "hilja", "hille", "hillevi", "hilma", "hilmar", "hiram", "hirokazu", "hiroki", "hiroshi", "hiroto", "hiroyasu", "hiroyuki",
  "hisako", "hisham", "hitomi", "hitoshi", "holger", "honorata", "hope", "horst", "hortense", "howard", "hrafn", "hrvoje",
  "hryhorii", "hubert", "hubertus", "huda", "hugh", "hugo", "huguette", "hulda", "humbert", "husnu", "hussein", "huw",
  "hyacinthe", "iain", "ian", "ibolya", "ibrahim", "ichiro", "ida", "ignac", "ignatius", "ignaz", "igor", "ihor",
  "iiro", "iker", "ikshvaku", "ilan", "ilana", "ilario", "ildiko", "ileana", "ilhan", "ilir", "ilja", "ilkka",
  "ilmar", "ilmari", "ilmi", "ilona", "ilse", "ilya", "ilyas", "imad", "iman", "imants", "imelda", "immanuel",
  "imogen", "imran", "imre", "imrich", "ina", "inaki", "india", "indrek", "ines", "inez", "inga", "ingar",
  "inge", "ingeborg", "ingegerd", "ingemar", "inger", "ingmar", "ingo", "ingolf", "ingrid", "ingrida", "ingunn", "ingvald",
  "ingvar", "ingvild", "inigo", "inna", "ioan", "ioana", "ioann", "ioannes", "ioannis", "ionut", "iorwerth", "iosif",
  "ira", "irad", "irakli", "irena", "irenaus", "irene", "ireneusz", "irina", "iris", "irja", "irma", "irmgard",
  "isa", "isaak", "isabel", "isabella", "isabelle", "isaias", "isak", "isao", "ishana", "isidor", "isidora", "isidore",
  "isis", "isla", "islam", "ismael", "ismail", "ismet", "isolde", "issam", "istvan", "itai", "italia", "itziar",
  "iva", "ivan", "ivana", "ivanka", "ivar", "iveta", "ivica", "ivo", "ivona", "ivor", "izabela", "izabella",
  "izak", "izidor", "ja'far", "jaak", "jaakko", "jaan", "jacek", "jacinta", "jack", "jackson", "jacob", "jacopo",
  "jacqueline", "jacques", "jadabharata", "jade", "jadranka", "jadwiga", "jafar", "jagoda", "jaime", "jair", "jake", "jakob",
  "jakov", "jakub", "jalen", "jalmari", "james", "jamie", "jamil", "jamila", "jan", "jana", "janbai", "jane",
  "janet", "janez", "janice", "janina", "janis", "janko", "janne", "jannike", "janos", "janus", "janusz", "jared",
  "jari", "jarkko", "jarl", "jarmila", "jarmo", "jarno", "jaromir", "jaroslav", "jaroslava", "jasmin", "jasmina", "jasmine",
  "jasna", "jason", "jasper", "jaume", "javier", "jawad", "jay", "jayson", "jean", "jean-baptiste", "jean-claude", "jean-jacques",
  "jean-louis", "jean-luc", "jean-marie", "jean-pierre", "jean-yves", "jeanette", "jeanne", "jeannette", "jedediah", "jeff", "jefferson", "jeffrey",
  "jela", "jelena", "jelka", "jelle", "jemima", "jenna", "jennifer", "jenny", "jeno", "jens", "jenson", "jeremiah",
  "jeremias", "jeremy", "jerker", "jermaine", "jeroen", "jerome", "jeronimo", "jerry", "jerzy", "jesper", "jess", "jesse",
  "jessica", "jessie", "jesus", "jethro", "ji-min", "ji-u", "jill", "jim", "jimena", "jimmy", "jindrich", "jiri",
  "jiro", "jitka", "joachim", "joacim", "joakim", "joan", "joana", "joanna", "joanne", "joao", "joaquim", "joaquin",
  "job", "jocelyn", "jocelyne", "jochen", "joel", "jogvan", "johan", "johann", "johanna", "johanne", "johannes", "john",
  "johnny", "jolan", "jolanda", "jolanta", "jon", "jonah", "jonatan", "jonathan", "jone", "jonna", "jonne", "jonny",
  "joona", "joonas", "joost", "joran", "jordanka", "jorg", "jorge", "joris", "jorma", "jorn", "jorunn", "jose",
  "josef", "josefa", "josefina", "josefine", "joseph", "josephine", "joshua", "josiah", "josif", "josip", "jostein", "josu",
  "jouko", "jovan", "joy", "joyce", "jozef", "jozsef", "juan", "juana", "juda", "judas", "judit", "judith",
  "judy", "juha", "juhani", "juho", "jukka", "julia", "julian", "juliana", "juliane", "julianna", "julianne", "julie",
  "julien", "juliette", "julija", "julio", "julius", "juliusz", "junji", "junko", "juraj", "jurgen", "jurgis", "jurij",
  "jussi", "justin", "justina", "justine", "justus", "justyna", "jutta", "juuso", "jyri", "jyrki", "jytte", "kaare",
  "kaarle", "kaarlo", "kacper", "kadir", "kai", "kaija", "kaisa", "kaja", "kajetan", "kaleva", "kalevi", "kalina",
  "kalju", "kalle", "kalman", "kamal", "kamala", "kamil", "kamila", "kamilla", "kamran", "kaori", "kaoru", "kara",
  "kare", "karel", "karen", "kari", "karim", "karin", "karina", "karine", "karl", "karla", "karlis", "karlo",
  "karol", "karola", "karolina", "karoline", "karolis", "karoly", "kasimir", "kaspar", "kaspars", "kasper", "kata", "katalin",
  "katariina", "katarina", "katarzyna", "kate", "katerina", "katharina", "katharine", "katherine", "kathleen", "kathryn", "kathy", "kati",
  "katia", "katie", "katinka", "katja", "katrin", "katrina", "katrine", "katsuhiro", "katsumi", "kauko", "kawthar", "kayla",
  "kaylee", "kazimiera", "kazimira", "kazuaki", "kazuhiro", "kazuhito", "kazuki", "kazuko", "kazuo", "kazuto", "keanu", "keiichi",
  "keijo", "keiko", "keisha", "keisuke", "keith", "kelly", "kelvin", "ken", "ken'ichi", "kenan", "kendra", "kenji",
  "kennedy", "kenneth", "kent", "kentaro", "kenzo", "kersti", "kerstin", "kerttu", "kestutis", "kettil", "kevin", "khadija",
  "khalil", "khatun", "khosrow", "khristofor", "kieran", "kiko", "kilian", "kim", "kimberly", "kimiko", "kimmo", "kinga",
  "kinsley", "kira", "kirill", "kirk", "kirsi", "kirsten", "kirsti", "kirstine", "kitty", "kjartan", "kjell", "kjerstin",
  "kjetil", "klara", "klas", "klaudia", "klaudiusz", "klaus", "klemens", "klement", "kleopatra", "knud", "knut", "kofi",
  "koichi", "koji", "koki", "koldo", "koloman", "konrad", "konstantin", "kornel", "kornelia", "kornelius", "kosta", "kotaro",
  "kotori", "kris", "krista", "kristaps", "kristel", "kristen", "krister", "kristian", "kristiina", "kristin", "kristina", "kristine",
  "kristjan", "krisztina", "krunoslav", "krystof", "krystyna", "krzysztof", "ksenija", "kumiko", "kunibert", "kunigunde", "kuno", "kurt",
  "kustaa", "kuzma", "kwadwo", "kwame", "kwasi", "kyla", "kyle", "kyllikki", "kyoko", "kyosti", "lachlan", "lada",
  "ladislav", "ladislava", "laetitia", "laila", "lajos", "lalla", "lambert", "lamberto", "lana", "lance", "lara", "larisa",
  "larissa", "larry", "lars", "lasse", "laszlo", "latif", "latifa", "laura", "lauren", "laurent", "laurentius", "lauri",
  "lauritz", "lavinia", "lavrentiy", "lawrence", "layla", "lea", "leander", "leandra", "leandro", "lech", "lee", "leia",
  "leif", "leila", "leilani", "leire", "leiv", "lelio", "lemuel", "lena", "lene", "lenka", "lennart", "leo",
  "leon", "leona", "leonard", "leonardo", "leonel", "leonhard", "leonid", "leonora", "leonti", "leontina", "leopold", "lester",
  "leszek", "letitia", "lev", "levente", "levi", "levin", "lewis", "leyla", "lia", "liam", "liana", "libero",
  "libor", "libuse", "lidia", "lidija", "lidiya", "lieke", "liina", "liisa", "liisi", "lila", "lili", "lilia",
  "lilian", "liliana", "lilith", "lilja", "lillian", "lilly", "lily", "lina", "linda", "lindsay", "line", "linn",
  "linnea", "linus", "lionel", "lipot", "liridon", "lisa", "lisbet", "lisbeth", "lise", "liselotte", "lisette", "liv",
  "livia", "liz", "liza", "ljubica", "ljubisa", "ljubo", "ljudevit", "ljudmila", "lloyd", "lluis", "logan", "loic",
  "lola", "lolita", "lone", "lorant", "loredana", "lorena", "lorenz", "lorenzo", "loreta", "loretta", "lorinc", "lorna",
  "lorraine", "lothar", "lotta", "lotte", "lou", "louis", "louise", "lovisa", "lovro", "lubomir", "lubomira", "lubos",
  "luc", "luca", "lucas", "lucia", "luciana", "luciano", "lucie", "lucien", "lucinda", "lucio", "lucius", "lucjan",
  "lucy", "ludger", "ludivine", "ludmila", "ludmilla", "ludo", "ludolf", "ludovic", "ludovica", "ludovit", "ludvig", "ludvik",
  "ludwig", "ludwik", "ludwika", "luigi", "luis", "luisa", "luitgard", "luiza", "luka", "lukas", "luke", "luna",
  "lydia", "lynette", "lynn", "lyubov", "lyudmila", "maaike", "maarit", "mabel", "maciej", "mackenzie", "madeleine", "madhu",
  "madina", "madis", "madison", "mads", "mae", "maeve", "maffeo", "magda", "magdalena", "magdalene", "maggie", "magnar",
  "magne", "magnhild", "magnus", "mahadevi", "mahagauri", "mahanaim", "mahir", "mahmud", "mahmut", "mahound", "mahsa", "maia",
  "maike", "maiken", "maila", "maire", "maite", "maja", "makarios", "maksim", "malak", "malcolm", "malene", "malik",
  "malika", "malin", "malina", "malinda", "malte", "malvin", "malvina", "malwina", "mandy", "manfred", "manisha", "manon",
  "mans", "mansur", "mantas", "manuel", "manuela", "mara", "marat", "marc", "marcel", "marcela", "marcella", "marcelo",
  "marcia", "marcin", "marco", "marcos", "marcus", "marek", "maren", "margaret", "margareta", "margaretha", "margarida", "margarita",
  "marge", "margery", "margherita", "margit", "margita", "margot", "margret", "margrete", "margrethe", "marguerite", "mari", "maria",
  "mariah", "mariam", "marian", "mariana", "mariann", "marianna", "marianne", "mariano", "marica", "marie", "mariel", "marielle",
  "marija", "marijan", "marijana", "marika", "marilyn", "marin", "marina", "marinko", "marinus", "mario", "marion", "marisa",
  "mariska", "marit", "marius", "mariusz", "marja", "marjatta", "marjo", "marjorie", "marjut", "mark", "marketa", "markku",
  "marko", "markus", "marleen", "marlena", "marlene", "marlon", "marta", "marten", "martha", "marthe", "martin", "martina",
  "martine", "martino", "martinus", "marton", "martti", "marvin", "marwa", "mary", "maryam", "marzena", "masaaki", "masahiro",
  "masahito", "masako", "masami", "masanobu", "masanori", "masao", "masaru", "masashi", "masato", "masayuki", "masha", "mason",
  "massimiliano", "massimo", "mate", "matea", "matej", "mateo", "mateusz", "mathias", "mathilde", "matias", "matija", "matilda",
  "matilde", "matjaz", "mats", "matt", "matteo", "matthaus", "matthew", "matthias", "matti", "mattia", "mattias", "mattis",
  "matvey", "matyas", "maud", "mauno", "maura", "maureen", "maurice", "mauricio", "maurits", "maurizio", "mauro", "mavis",
  "max", "maxim", "maximilian", "may", "maya", "meagan", "meaghan", "mecislovas", "medard", "medea", "meelis", "meg",
  "megan", "meghan", "mehmet", "mehrdad", "meinrad", "melania", "melanie", "melchior", "melina", "melinda", "melis", "melisa",
  "melissa", "meliton", "melody", "mels", "melvin", "meng", "mercedes", "meredith", "merete", "meritites", "merve", "mervi",
  "mervyn", "meta", "mette", "mia", "micael", "micaela", "micah", "micha", "michael", "michaela", "michail", "michel",
  "michela", "michelangelo", "michele", "michelle", "michiel", "michiko", "michio", "mieszko", "miguel", "miha", "mihailo", "mihaly",
  "mihkel", "miika", "miina", "mikael", "mikaela", "mike", "mikhail", "mikkel", "mikko", "miklos", "miko", "mila",
  "milada", "milan", "milana", "milda", "mildred", "milena", "miles", "milica", "milivoj", "milja", "milka", "milko",
  "milla", "millicent", "milo", "milorad", "milos", "miloslav", "milovan", "milton", "mina", "mindaugas", "minna", "minoru",
  "mio", "mira", "miranda", "mircea", "mireille", "mirela", "mirella", "miriam", "mirja", "mirjam", "mirjana", "mirka",
  "mirko", "mirna", "miro", "miroslav", "miroslava", "mirsad", "mitja", "mitsuo", "mitsuru", "miyu", "mladen", "modestas",
  "mogens", "mohammad-reza", "mohyeddin", "moira", "mojca", "mojmir", "molly", "mona", "monica", "monika", "monique", "montserrat",
  "morgan", "moric", "moritz", "morten", "moses", "moshe", "motoko", "mstislav", "muhammad", "mukesh", "mulay", "murad",
  "murat", "muriel", "muslim", "mustafa", "mykhailo", "mykola", "mykolas", "myra", "myriam", "nabil", "nada", "nadezhda",
  "nadia", "nadine", "nadir", "nadja", "nafisa", "nahum", "nail", "naima", "najma", "nana", "nanami", "nancy",
  "nandor", "nanna", "naoki", "naoko", "naomi", "naoto", "napoleone", "narcis", "narcisa", "nasser", "natacha", "natale",
  "natalia", "natalie", "nataliia", "nataliya", "natanael", "natascha", "natasha", "natasja", "nate", "nathalie", "nathan", "nathanael",
  "nathaniel", "natsuki", "natsuko", "natsumi", "nazar", "nazario", "nazim", "nebojsa", "necati", "necmettin", "nedeljko", "neferu",
  "neil", "nekane", "nela", "nelly", "nelson", "nemain", "nemanja", "nenad", "nepomuk", "nerea", "nesrin", "nestor",
  "nestori", "neven", "nevena", "nevenka", "nevio", "niall", "niamh", "niccolo", "nicholas", "nico", "nicodemus", "nicola",
  "nicolaas", "nicolas", "nicolaus", "nicole", "nicoletta", "niels", "nigel", "niina", "nika", "nikanor", "nike", "nikita",
  "niklas", "nikodem", "nikola", "nikolai", "nikolaj", "nikolaos", "nikolaus", "nikolay", "nikoline", "nils", "nilufar", "nilufer",
  "nimi", "nina", "nino", "noam", "nobuko", "nobuo", "nobuyuki", "noe", "noel", "nonna", "noora", "nora",
  "norbert", "norberto", "noriaki", "noriko", "norma", "norman", "novak", "nuno", "nur", "nuria", "octavio", "odd",
  "oddvar", "odette", "odo", "odoardo", "odon", "ofelia", "ognjen", "oksana", "ola", "olaf", "olafur", "olaus",
  "olav", "olavi", "ole", "oleg", "oleksandr", "oleksii", "olena", "olga", "olgierd", "oliver", "olivia", "olivier",
  "olle", "olof", "olympia", "omar", "ondrej", "onni", "onno", "onur", "oona", "oreste", "orhan", "oriana",
  "oriol", "orion", "orjan", "orlando", "ornella", "orsolya", "orvar", "osama", "oscar", "oskar", "oskari", "oskars",
  "osman", "osmo", "osmund", "osten", "osvald", "osvaldo", "oswald", "oszkar", "otilia", "otis", "otmar", "oto",
  "ottavio", "ottilia", "ottilie", "otto", "ove", "owen", "ozge", "ozlem", "paavo", "pablo", "paco", "paddy",
  "padmavati", "padraig", "paisley", "pal", "pall", "palle", "paloma", "pamela", "panagiotis", "panchakanya", "pancho", "pantaleon",
  "panteleimon", "paola", "paolo", "paraskeva", "paris", "parker", "pascal", "pasquale", "patrice", "patricia", "patrick", "patrik",
  "patrizia", "patryk", "paul", "paula", "paulina", "pauline", "paulius", "paulo", "paulus", "pausanias", "pavel", "pavla",
  "pavle", "pavlina", "peder", "pedro", "peeter", "peggy", "pekka", "pelle", "penelope", "pentti", "pepe", "per",
  "percival", "pernilla", "pernille", "pero", "pertti", "petar", "pete", "peter", "petko", "petra", "petri", "petro",
  "petronella", "petru", "petrus", "petter", "petur", "philip", "phineas", "phoebe", "phyllis", "pia", "pierluigi", "piero",
  "pierre", "pieter", "pietro", "piia", "pilar", "piotr", "pirjo", "pirkko", "piroska", "pius", "platon", "pol",
  "polina", "pontus", "poul", "prakash", "preben", "predrag", "premysl", "priidu", "priit", "primoz", "priscilla", "prithu",
  "priya", "prosper", "prsnigarbha", "ptolemy", "pula", "purushottama", "pyotr", "quentin", "quinn", "qurban", "rachel", "radbod",
  "radka", "radmila", "radomir", "radoslav", "radovan", "rafael", "raffaella", "rafik", "rafiq", "ragna", "ragnar", "ragnhild",
  "ragnvald", "rahman", "raili", "raimo", "raimondas", "raimundas", "rainer", "raisa", "raivis", "raivo", "rajesh", "rajiv",
  "rajko", "rajmund", "rakel", "ralf", "ralph", "ramesh", "ramesses", "rami", "ramil", "ramon", "ramona", "rana",
  "randall", "randi", "randy", "rani", "raoul", "raphael", "raquel", "rashid", "rasim", "rasmus", "ratko", "ratri",
  "raul", "rauno", "rayan", "raymond", "raymund", "razvan", "rebeca", "rebecca", "rebeka", "rebekka", "recep", "regina",
  "reginald", "regine", "reidar", "reijo", "rein", "reinaldo", "reinhard", "reinhold", "reinier", "reka", "rembrandt", "remo",
  "renat", "renata", "renate", "renato", "renatus", "rene", "renee", "rens", "reuben", "rex", "reza", "rhys",
  "ria", "ricardo", "riccardo", "richa", "richard", "rick", "rifat", "rigmor", "rigobert", "rihards", "riina", "riitta",
  "rikard", "rikke", "riku", "riley", "rima", "rimma", "rina", "rino", "rinus", "risto", "rita", "ritva",
  "roald", "roar", "rob", "robert", "roberta", "roberto", "robin", "rocco", "roch", "rocio", "rodion", "rodolfo",
  "rodrigo", "roel", "roelof", "rogelio", "roger", "roland", "rolando", "rolf", "roma", "roman", "romana", "romeo",
  "romilda", "romina", "romuald", "romy", "ron", "ronald", "ronaldo", "ronan", "ronja", "ronny", "rory", "rosa",
  "rosalba", "rosalia", "rosalie", "rosalind", "rosalinda", "rosanna", "rosario", "rose", "rosemary", "rosina", "rosita", "ross",
  "rossana", "rostislav", "roswitha", "roxana", "roy", "ruben", "ruby", "rudi", "rudolf", "rufina", "rufus", "ruggero",
  "runar", "rune", "ruqayyah", "ruslan", "russell", "rut", "rutger", "ruth", "ruxandra", "ryan", "ryota", "ryszard",
  "ryuichi", "sabin", "sabina", "sabine", "sabrina", "saburo", "sadako", "saddam", "sadik", "sadiq", "safet", "sahar",
  "saida", "sakari", "sakarias", "saki", "saleh", "salim", "sally", "salma", "salome", "salvador", "salvatore", "sam",
  "samad", "samanta", "samantha", "samar", "sami", "samir", "samira", "samson", "samuel", "sancho", "sandor", "sandra",
  "sandro", "sandy", "sanja", "sanna", "sanne", "santeri", "santiago", "saoirse", "sara", "sarah", "sarunas", "sasa",
  "saskia", "satoru", "satoshi", "satu", "saul", "saulius", "savely", "saverio", "sayyid", "scarlett", "scott", "seamus",
  "sean", "sebald", "sebastian", "sebastiano", "sebastien", "selena", "selim", "selina", "selma", "semyon", "senol", "sepideh",
  "sepp", "seppo", "serafim", "serafima", "serena", "serge", "sergej", "sergey", "sergio", "sergiu", "sergius", "serhii",
  "seth", "severin", "severino", "seymour", "shahla", "shailaputri", "shannon", "shapur", "sharon", "shayma", "sheila", "sheldon",
  "shigeru", "shin", "shin'ichi", "shin'ya", "shinji", "shinzo", "shirin", "shirley", "shiro", "shizuka", "shlomo", "shota",
  "siarhiej", "sibel", "sibylla", "sidney", "siegbert", "siegfried", "sieglinde", "sienna", "sietske", "sigfrid", "sigismund", "sigmar",
  "sigmund", "signe", "sigrid", "sigrun", "sigurd", "sigvard", "sigve", "silas", "silja", "silje", "silke", "silva",
  "silvan", "silvana", "silvester", "silvia", "silvija", "silvio", "silviu", "simas", "sime", "simen", "simeon", "simo",
  "simon", "simona", "simonas", "simone", "sinikka", "sinisa", "sinivali", "siobhan", "siri", "sissel", "siv", "sivert",
  "sixten", "sixtus", "skylar", "skyler", "slaven", "slavko", "slavoljub", "slavomir", "slobodan", "snefrid", "snorre", "sofia",
  "sofie", "sofija", "sohil", "solange", "solveig", "sondre", "sonia", "sonja", "sonny", "sophia", "sophie", "soren",
  "sorin", "sotirios", "spencer", "spyridon", "srecko", "sreten", "srivatsa", "staffan", "stale", "stanislaus", "stanislav", "stanislava",
  "stanley", "steen", "stefan", "stefania", "stefanie", "stefano", "steffi", "steinar", "stela", "stella", "stellan", "sten",
  "stepan", "stephane", "stephanie", "stephen", "stevan", "steve", "steven", "stian", "stig", "stina", "stine", "stjepan",
  "sture", "sturla", "stylianos", "styrbjorn", "sulamith", "suleiman", "suleyman", "sulo", "sultan", "sumaya", "sune", "sunniva",
  "suresh", "susan", "susanna", "susanne", "susumu", "suzana", "suzanne", "svanhild", "svante", "svea", "svein", "sveinn",
  "sveinung", "sven", "svend", "svenja", "sverker", "sverre", "svetlana", "sviatoslav", "sybil", "sylvain", "sylvi", "sylvia",
  "sylwester", "szabolcs", "szczepan", "szilard", "szilvia", "szymon", "taavi", "tabita", "tabitha", "tadas", "tadashi", "tadej",
  "tadeusz", "tadhg", "tage", "taha", "tahar", "tahir", "taichi", "tailtiu", "taisto", "takahiro", "takashi", "takayuki",
  "takeshi", "takuya", "talha", "talitha", "tamar", "tamara", "tamas", "tanel", "taneli", "taner", "tanja", "tankred",
  "tapio", "tara", "taras", "tarcisio", "tarek", "tariq", "tarja", "tarjei", "tarkan", "tarmo", "taro", "tasha",
  "tatiana", "tatjana", "tatsuya", "tauno", "tawfik", "taylor", "tea", "teemu", "teimuraz", "tekla", "telma", "tenzin",
  "teo", "teobald", "teodor", "teodora", "teofil", "teofila", "teoman", "terence", "terenzio", "teresa", "teresia", "terez",
  "tereza", "terezia", "terje", "tessa", "tetsu", "tevfik", "thaddeus", "thalia", "thea", "thelma", "theo", "theobald",
  "theodor", "theodora", "theodore", "theodoric", "theodorus", "theophilus", "theresa", "therese", "thierry", "thomas", "thompson", "thor",
  "thoralf", "thorbjorn", "thore", "thorleif", "thorsten", "thorvald", "tiago", "tiberiu", "tiberius", "tibor", "tiffany", "tihamer",
  "tihomir", "tiia", "tiina", "tiit", "tijana", "tikhon", "tilde", "tilman", "tim", "timea", "timo", "timofey",
  "timon", "timotej", "timothee", "timotheos", "timothy", "tin", "tina", "tito", "titus", "titusz", "tivadar", "tiziano",
  "tobias", "toby", "todd", "todor", "toini", "toivo", "tolga", "tom", "tomas", "tomasz", "tomislav", "tommaso",
  "tommi", "tommy", "tomoko", "tonantzin", "toni", "tonibler", "tonis", "tonje", "tonu", "tony", "toomas", "tor",
  "tora", "toralf", "torben", "torbjorn", "tord", "tordis", "tore", "torfinn", "torgeir", "torgny", "torkel", "torleif",
  "tormod", "tornike", "torolf", "torstein", "torsten", "torsti", "toru", "torvald", "toshio", "tova", "tove", "tracy",
  "travis", "tricia", "trine", "tristan", "trond", "troy", "trude", "truls", "tryggve", "tryggvi", "trygve", "tsukasa",
  "tsutomu", "tsuyoshi", "tuba", "tugce", "tuija", "tullio", "tunde", "tuomas", "tuomo", "ture", "tuukka", "tuuli",
  "tycho", "tyko", "tyler", "tymoteusz", "tyra", "ubaldo", "udo", "ueli", "uffe", "ufuk", "ugo", "ugur",
  "ulf", "uliana", "ulla", "ulo", "ulric", "ulrica", "ulrich", "ulrik", "ulrika", "ulrike", "ulrikke", "umberto",
  "unai", "urban", "uri", "uriel", "urmas", "uros", "urpo", "ursula", "ute", "uthman", "uuno", "uwe",
  "vaclav", "vadim", "vagn", "vahe", "vaino", "valborg", "valdar", "valdas", "valdemar", "valdemaras", "valdis", "valentin",
  "valentina", "valentino", "valeria", "valerian", "valerie", "valerio", "valery", "valfrid", "valter", "valtteri", "vanda", "vanessa",
  "vanja", "varahi", "vardan", "varuni", "vasco", "vasil", "vasilisa", "vasily", "vaso", "vedran", "vegard", "veikko",
  "veli", "velibor", "vendelin", "veniamin", "venla", "vera", "verena", "verner", "veronica", "veronika", "veronique", "vesa",
  "veselin", "vesna", "vibeke", "vicente", "victor", "victoria", "vid", "vidar", "vigdis", "viggo", "vijay", "viktor",
  "viktoria", "viktorija", "vilem", "vilhelm", "vilho", "viliam", "vilibald", "vilis", "vilja", "viljar", "viljo", "ville",
  "vilma", "vilmos", "vinayaki", "vincas", "vince", "vincenc", "vincent", "vincenzo", "vinod", "vinzenz", "viola", "violante",
  "violet", "violeta", "violetta", "viorel", "viorica", "virgilio", "virginia", "vita", "vitalii", "vitalijus", "vito", "vitomir",
  "vitor", "vittorio", "vitus", "viveca", "vivian", "viviana", "vladan", "vladimir", "vladimiro", "vladislav", "vladlen", "vlado",
  "vlasta", "vlastimil", "vojislav", "voldemars", "volkan", "volkmar", "volodymyr", "vratislav", "vsevolod", "vuk", "vukasin", "vyacheslav",
  "vytautas", "walburga", "waldemar", "waleed", "walenty", "waleran", "wallace", "walter", "waltraud", "wanda", "warren", "wawrzyniec",
  "wayne", "wenche", "wendy", "werner", "widukind", "wiebke", "wiktor", "wiktoria", "wilfrid", "wilfried", "wilhelm", "wilhelmina",
  "will", "willem", "william", "willy", "wilma", "wim", "winfried", "winifred", "winnie", "winona", "winston", "witold",
  "wladimir", "wojciech", "wolfgang", "wolfhard", "wouter", "wyatt", "xabier", "xaver", "xavier", "xenia", "ximena", "xiomara",
  "yael", "yair", "yakub", "yann", "yannick", "yara", "yaroslav", "yasmin", "yasser", "yaw", "yegor", "yelena",
  "yelisey", "yelizaveta", "yemelyan", "yeshu", "yeshua", "yevdokiya", "yevgeny", "yevhen", "yitzhak", "ylva", "yngvar", "yngve",
  "yogamaya", "yohanan", "yoko", "yolanda", "yoshihiro", "yrjo", "yuji", "yukio", "yumi", "yunus", "yurika", "yuriko",
  "yury", "yusuf", "yusuke", "yves", "yvette", "yvonne", "zacharie", "zachary", "zahra", "zaira", "zaki", "zara",
  "zarko", "zaynab", "zbigniew", "zbynek", "zdenek", "zdenko", "zdravko", "ze'ev", "zelda", "zeljko", "zenaida", "zenobia",
  "zenon", "zephaniah", "zeynep", "zhanna", "zina", "zinaida", "zinoviy", "zita", "zivile", "ziya", "zlata", "zlatan",
  "zlatko", "zoe", "zoey", "zofia", "zoltan", "zora", "zoran", "zorica", "zoticus", "zsanett", "zsofia", "zsolt",
  "zsombor", "zsuzsanna", "zulfiya", "zurab", "zuzana", "zuzanna", "zvezdan", "zvonimir", "zvonko", "zygmunt",
]);

// Surnames (2026-10-29 expansion): the original hand list ∪ the US Census 2010 top-1,000 surnames (public
// domain), minus any name that is also a given name (Tyler, Taylor, Jordan… stay given names).
// Mirror: ContentModeration.swift commonLastNames.
const COMMON_LAST_NAMES = new Set([
  "abbott", "acevedo", "acosta", "adams", "adkins", "aguilar", "aguirre", "alfaro", "allen", "allison", "alvarado", "alvarez",
  "andersen", "andrade", "andrews", "archer", "arellano", "arias", "armstrong", "arroyo", "atkins", "atkinson", "austin", "avalos",
  "avila", "ayala", "ayers", "bailey", "baker", "baldwin", "ball", "ballard", "banks", "barajas", "barber", "barker",
  "barnes", "barnett", "barr", "barrera", "barrett", "barron", "bartlett", "barton", "bass", "bates", "bauer", "bautista",
  "baxter", "bean", "beard", "beasley", "beck", "becker", "beil", "bell", "beltran", "bender", "benitez", "bennett",
  "benson", "bentley", "benton", "berg", "berger", "bernal", "berry", "best", "bishop", "black", "blackburn", "blackwell",
  "blair", "blanchard", "blankenship", "blevins", "bond", "bonilla", "booker", "boone", "booth", "bowen", "bowers", "bowman",
  "boyd", "boyer", "boyle", "bradford", "bradshaw", "branch", "brandt", "bravo", "bray", "brennan", "brewer", "bridges",
  "briggs", "brock", "brooks", "brown", "browning", "bryant", "buchanan", "buck", "buckley", "bullock", "burch", "burgess",
  "burke", "burnett", "burns", "burton", "bush", "butler", "byrd", "cabrera", "cain", "calderon", "caldwell", "calhoun",
  "callahan", "camacho", "campbell", "campos", "cannon", "cano", "cantrell", "cantu", "cardenas", "carey", "carlson", "carpenter",
  "carr", "carrillo", "carroll", "carson", "carter", "case", "castaneda", "castillo", "castro", "cervantes", "chambers", "chan",
  "chang", "chapman", "chase", "chavez", "chen", "cherry", "choi", "christensen", "chung", "church", "cisneros", "clark",
  "clarke", "clay", "clayton", "clements", "cline", "cobb", "cochran", "coffey", "cohen", "coleman", "collier", "collins",
  "colon", "combs", "compton", "conley", "conner", "conrad", "contreras", "conway", "cook", "cooper", "copeland", "cordova",
  "corona", "correa", "cortes", "cortez", "costa", "cox", "crane", "crawford", "crosby", "cross", "cruz", "cuevas",
  "cummings", "curry", "curtis", "daniels", "daugherty", "davenport", "davidson", "davila", "davis", "dawson", "day", "decker",
  "dejesus", "delacruz", "delarosa", "deleon", "delgado", "diaz", "dickerson", "dickson", "dillon", "dixon", "dodson", "dominguez",
  "donaldson", "donovan", "dorsey", "dougherty", "doyle", "drake", "duarte", "dudley", "duffy", "duke", "dunlap", "dunn",
  "duran", "durham", "dyer", "eaton", "edwards", "elliott", "ellis", "ellison", "enriquez", "erickson", "escobar", "esparza",
  "espinosa", "espinoza", "esquivel", "estes", "estrada", "evans", "everett", "farley", "farmer", "farrell", "faulkner", "ferguson",
  "fernandez", "fields", "figueroa", "fischer", "fisher", "fitzgerald", "fitzpatrick", "fleming", "flores", "flowers", "floyd", "flynn",
  "foley", "ford", "foster", "fowler", "fox", "frazier", "freeman", "friedman", "frost", "fry", "frye", "fuentes",
  "fuller", "gaines", "galindo", "gallagher", "gallegos", "galloway", "galvan", "garcia", "gardner", "garner", "garrison", "garza",
  "gates", "gentry", "gibbs", "gibson", "giles", "gill", "gillespie", "gilmore", "glass", "glover", "golden", "gomez",
  "gonzales", "gonzalez", "good", "goodman", "goodwin", "gould", "graves", "gray", "green", "greene", "greer", "griffin",
  "griffith", "grimes", "gross", "guerra", "guerrero", "guevara", "gutierrez", "guzman", "haas", "hahn", "hail", "hale",
  "haley", "hall", "hamilton", "hammond", "hampton", "hancock", "hansen", "hanson", "hardin", "harding", "harmon", "harrell",
  "harrington", "harris", "harrison", "hart", "hartman", "harvey", "hawkins", "hayden", "hayes", "haynes", "heath", "hebert",
  "henderson", "hendricks", "hendrix", "hensley", "henson", "hernandez", "herrera", "herring", "hess", "hester", "hickman", "hicks",
  "higgins", "hill", "hines", "hinton", "hobbs", "hodge", "hodges", "hoffman", "hogan", "holden", "holland", "holloway",
  "holmes", "holt", "hood", "hoover", "hopkins", "horn", "horne", "horton", "house", "houston", "howe", "howell",
  "huang", "hubbard", "huber", "hudson", "huerta", "huff", "huffman", "hughes", "hull", "humphrey", "hunt", "hunter",
  "hurley", "hurst", "hutchinson", "huynh", "ibarra", "ingram", "jacobs", "jacobson", "jaramillo", "jarvis", "jenkins", "jennings",
  "jensen", "jimenez", "johns", "johnson", "johnston", "jones", "jordan", "juarez", "kane", "kaufman", "kaur", "keller",
  "kelley", "kemp", "kerr", "khan", "king", "kirby", "klein", "kline", "knapp", "knight", "knox", "koch",
  "kramer", "krueger", "lam", "lamb", "landry", "lane", "lang", "larsen", "larson", "lawson", "leach", "leal",
  "leblanc", "levy", "lim", "lin", "lincoln", "lindsey", "little", "liu", "livingston", "long", "lopez", "love",
  "lowe", "lowery", "lozano", "lucero", "lugo", "lynch", "lyons", "macdonald", "macias", "mack", "madden", "maddox",
  "magana", "mahoney", "maldonado", "malone", "mann", "manning", "marks", "marquez", "marsh", "marshall", "martinez", "massey",
  "mata", "mathews", "mathis", "matthews", "maxwell", "mayer", "maynard", "mayo", "mays", "mcbride", "mccall", "mccann",
  "mccarthy", "mccarty", "mcclain", "mcclure", "mcconnell", "mccormick", "mccoy", "mccullough", "mcdaniel", "mcdonald", "mcdowell", "mcfarland",
  "mcgee", "mcgrath", "mcguire", "mcintosh", "mcintyre", "mckay", "mckee", "mckenzie", "mckinney", "mclaughlin", "mclean", "mcmahon",
  "mcmillan", "mcpherson", "meadows", "medina", "medrano", "mejia", "melendez", "melton", "mendez", "mendoza", "mercado", "merritt",
  "meyer", "meyers", "meza", "middleton", "miller", "mills", "mitchell", "molina", "monroe", "montes", "montgomery", "montoya",
  "moody", "moon", "moore", "mora", "morales", "moran", "moreno", "morris", "morrison", "morrow", "morse", "morton",
  "mosley", "moss", "moyer", "mueller", "mullen", "mullins", "munoz", "murillo", "murphy", "murray", "myers", "nash",
  "nava", "navarro", "neal", "newman", "newton", "nguyen", "nichols", "nicholson", "nielsen", "nieves", "nixon", "noble",
  "nolan", "norris", "norton", "nunez", "obama", "obrien", "ochoa", "oconnell", "oconnor", "odom", "odonnell", "olsen",
  "olson", "oneal", "oneill", "orozco", "orr", "ortega", "ortiz", "osborne", "owens", "pace", "pacheco", "padilla",
  "page", "palacios", "palmer", "park", "parks", "parra", "parrish", "parsons", "patel", "patterson", "patton", "payne",
  "pearson", "peck", "pena", "pennington", "peralta", "perez", "perkins", "perry", "person", "peters", "petersen", "peterson",
  "petty", "pham", "phan", "phelps", "phillips", "pierce", "pineda", "pittman", "pitts", "pollard", "ponce", "poole",
  "pope", "porter", "portillo", "potter", "potts", "powell", "powers", "pratt", "preston", "price", "prince", "proctor",
  "pruitt", "pugh", "quintana", "quintero", "ramirez", "ramos", "ramsey", "randolph", "rangel", "rasmussen", "ray", "reed",
  "reese", "reeves", "reid", "reilly", "reyes", "reyna", "reynolds", "rhodes", "rice", "rich", "richards", "richardson",
  "richmond", "rios", "rivas", "rivera", "rivers", "roach", "robbins", "roberson", "roberts", "robertson", "robinson", "robles",
  "rocha", "rodgers", "rodriguez", "rogers", "rojas", "rollins", "romero", "rosales", "rosas", "roth", "rowe", "rowland",
  "rubio", "ruiz", "rush", "russo", "salas", "salazar", "salgado", "salinas", "sampson", "sanchez", "sanders", "sandoval",
  "sanford", "santana", "santos", "saunders", "savage", "sawyer", "schaefer", "schmidt", "schmitt", "schneider", "schroeder", "schultz",
  "schwartz", "sellers", "serrano", "sexton", "shaffer", "shah", "sharp", "shaw", "shelton", "shepard", "shepherd", "sheppard",
  "sherman", "shields", "short", "sierra", "simmons", "simpson", "sims", "singh", "singleton", "skinner", "sloan", "small",
  "smith", "snow", "snyder", "solis", "solomon", "sosa", "soto", "sparks", "spears", "spence", "stafford", "stanton",
  "stark", "steele", "stein", "stephens", "stephenson", "stevens", "stevenson", "stewart", "stokes", "stone", "stout", "strickland",
  "strong", "stuart", "suarez", "sullivan", "summers", "sutton", "swanson", "sweeney", "tang", "tanner", "tapia", "tate",
  "terrell", "terry", "thornton", "torres", "townsend", "tran", "trejo", "trevino", "trujillo", "truong", "tucker", "turner",
  "underwood", "valdez", "valencia", "valentine", "valenzuela", "vance", "vang", "vargas", "vasquez", "vaughan", "vaughn", "vazquez",
  "vega", "velasquez", "velazquez", "velez", "ventura", "villa", "villalobos", "villanueva", "villarreal", "villegas", "wade", "wagner",
  "walker", "wall", "waller", "walls", "walsh", "walters", "walton", "wang", "ward", "ware", "warner", "washington",
  "waters", "watkins", "watson", "watts", "weaver", "webb", "weber", "webster", "weeks", "weiss", "welch", "wells",
  "west", "wheeler", "whitaker", "white", "whitehead", "whitney", "wiggins", "wilcox", "wiley", "wilkerson", "wilkins", "wilkinson",
  "williams", "williamson", "willis", "wilson", "winters", "wise", "wolf", "wolfe", "wong", "wood", "woodard", "woods",
  "woodward", "wright", "xiong", "yang", "yates", "yoder", "york", "young", "zamora", "zavala", "zhang", "zimmerman",
  "zuniga",
]);

// Names that are also ordinary words (2026-10-29 expansion): the original list ∪ a curated list of
// common-word surnames and given names (brown, white, young, hill, green, king, black, long, wood, rose,
// gray, wells, rich, bill, mark, will, joy, faith, summer, dawn, hope, grace, …). Never nudge, never count
// as a lone name. Deliberately NOT a dictionary intersection (that silenced 38 real given names).
// Mirror: ContentModeration.swift ambiguousWords.
const AMBIGUOUS_WORDS = new Set([
  "amber", "angel", "april", "art", "august", "autumn", "baby", "baker", "bay", "bell", "best", "bill",
  "bishop", "black", "bright", "brook", "brown", "bush", "candy", "carter", "cash", "chance", "charity", "chase",
  "cherry", "christian", "cliff", "cole", "cook", "crystal", "dale", "dawn", "day", "dean", "dear", "destiny",
  "don", "duke", "earl", "eve", "faith", "field", "fields", "fisher", "ford", "fox", "frank", "frost",
  "genesis", "ginger", "glen", "gold", "grace", "grant", "gray", "green", "grey", "guy", "harmony", "heath",
  "heaven", "hill", "holly", "honey", "hope", "hunter", "iris", "ivy", "jade", "joy", "june", "justice",
  "king", "knight", "lake", "lance", "lane", "liberty", "lily", "long", "love", "major", "mark", "mason",
  "max", "may", "melody", "mercy", "miles", "miller", "misty", "moon", "norm", "olive", "pace", "page",
  "park", "parker", "pat", "patience", "pearl", "penny", "precious", "price", "ray", "read", "reed", "rex",
  "rich", "rivers", "rock", "rod", "rose", "ruby", "sage", "sandy", "serenity", "sharp", "silver", "skip",
  "sky", "snow", "spring", "star", "stone", "storm", "stormy", "sue", "summer", "sun", "sunny", "taylor",
  "trinity", "turner", "van", "violet", "wade", "walker", "wells", "white", "will", "winter", "wolf", "wood",
  "young",
]);

// Owner decision 2026-10-30: five given names that are also ordinary words stay in AMBIGUOUS_WORDS,
// so NO hold rule ever treats them as a name ("my ex Dean" is not a lone-name hold, "Dean Miller" is
// not a full-name hold), but they still drive the soft compose NUDGE when Capitalized or right after a
// relationship prefix. Independent of COMMON_NAMES ("earl" is not in the given list). The contraction
// "don't" is stripped before matching so it never reads as the name Don.
// Mirror: ContentModeration.swift nudgeOnlyNames; docs/admin.html ADMIN_NUDGE_ONLY.
const NUDGE_ONLY_NAMES = new Set(["christian", "cole", "dean", "don", "earl"]);
const DONT_CONTRACTION_RE = /\b[Dd]on['’]t\b/g;

const SAFE_CAPITALIZED_WORDS = new Set([
  "i", "im", "ive", "ill", "id",
  "god", "christmas", "easter", "halloween", "valentines",
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  "january", "february", "march", "april", "june", "july", "august",
  "september", "october", "november", "december",
  "american", "english", "spanish", "french", "chinese", "japanese",
  "toska", "giphy", "apple", "google", "firebase",
  // "MacBook" pairs with a capitalized model word ("MacBook Pro"/"Air") that
  // the Mc/Mac-aware name regex would otherwise read as a surname. McDonald &
  // co. are NOT excluded — they're also real surnames ("Sean McDonald") and
  // the brand only false-positives in the rare "Old McDonald"-style phrase,
  // which is held-for-review (the safe direction) rather than deleted.
  "macbook",
]);

// Common two-word proper nouns that are NOT a person's name — places, brands,
// media, and capitalized greetings — so the full-name heuristic below doesn't
// hold "I miss New York" or "we watched Harry Potter". Long-tail proper nouns
// not listed here will still be held for review (the safe direction for an
// anonymity app — held, not deleted).
const SAFE_PROPER_NOUN_BIGRAMS = new Set([
  "new york", "new jersey", "new orleans", "new mexico", "new hampshire",
  "los angeles", "san francisco", "san diego", "san antonio", "san jose",
  "las vegas", "rhode island", "north carolina", "south carolina",
  "north dakota", "south dakota", "west virginia", "new zealand",
  "hong kong", "costa rica", "puerto rico", "united states", "united kingdom",
  "great britain", "saudi arabia", "south africa", "south korea",
  "taylor swift", "harry potter", "taco bell", "burger king", "old navy",
  "stranger things", "breaking bad", "black friday",
  "happy birthday", "happy holidays", "merry christmas",
  "good morning", "good evening", "good afternoon", "good night", "good luck",
  "thank god",
]);

// M-2 (2026-06-08 audit): common English words that appear Capitalized inside
// titles, place names, bands, and set phrases ("Last Night", "Central Park",
// "Pearl Jam", "Grand Canyon", "The Notebook", "Empty Promises"). The
// two-capitalized-words full-name heuristic below false-positived on every one
// of these on an app where grief posts are full of such phrases. A real
// person's full name is rarely built from two common English words, so if a
// bigram contains one of these AND neither token is a known given name, it's
// treated as a phrase, not a name. This is intentionally a common-ENGLISH-word
// list (a bounded, stable set) rather than an exhaustive non-name proper-noun
// list (which can't scale). Real names like "Sarah Jones" or the uncommon
// "Vera Marchetti" stay flagged because they don't contain a title word.
const COMMON_TITLE_WORDS = new Set([
  "the", "a", "an", "of", "and", "to", "in", "on", "at", "for",
  "last", "first", "next", "final", "every",
  "night", "day", "days", "morning", "evening", "afternoon", "today", "tomorrow", "yesterday",
  "central", "grand", "royal", "golden", "old", "new", "big", "little", "great",
  "park", "city", "town", "river", "lake", "mountain", "mountains", "ocean", "sea", "beach",
  "street", "avenue", "road", "drive", "lane", "garden", "gardens", "square", "bridge",
  "tower", "valley", "hill", "hills", "falls", "bay", "island", "forest", "woods", "creek",
  "heights", "view", "point", "north", "south", "east", "west", "upper", "lower", "middle",
  "house", "home", "world", "war", "story", "stories", "love", "heart", "hearts",
  "summer", "winter", "spring", "autumn", "fall", "sunset", "sunrise",
  "moon", "sun", "star", "stars", "light", "lights", "dark", "darkness",
  "dream", "dreams", "time", "times", "life", "death", "end", "ending", "beginning",
  "dead", "alive", "real", "true", "lost", "found", "broken", "empty", "promise", "promises",
  "gold", "silver", "blue", "red", "green", "white", "black", "gray", "grey",
  "fire", "water", "earth", "wind", "rain", "snow", "storm", "cloud", "clouds", "sky",
  "song", "songs", "music", "dance", "band", "club", "bar", "cafe", "coffee",
  "book", "books", "movie", "film", "show", "game", "games", "play", "party",
  "school", "college", "work", "office", "store", "shop", "mall", "market",
  "food", "dinner", "lunch", "breakfast", "pearl", "jam", "canyon", "notebook",
  "station", "airport", "university", "library", "museum", "hotel", "plaza",
  "center", "centre", "hall", "theater", "theatre", "stadium", "arena",
  "church", "temple", "castle", "palace", "diamond", "crystal", "rose", "stone",
]);

// Full-name shape: two consecutive Capitalized words ("Vera Marchetti",
// "John Smith") — a strong signal of a person's name even when neither word
// is in our first/last-name dictionaries. 2026-06-01: added after a real full
// name slipped through (uncommon name + no relationship context). Guards skip
// safe words, all-ambiguous pairs, known non-name bigrams, and (M-2) common
// English title/phrase bigrams. NOTE: this only catches the BOTH-capitalized
// shape; "Vera marchetti" (lowercase surname) and bare single names still slip
// — reliably catching those needs NER/ML.
function looksLikeFullName(text) {
  // Run the two-capitalized-words shape over the CANONICALIZED text, not the
  // raw text (F-1, 2026-06-12 security re-review). canonicalize folds math-
  // alphanumeric / fullwidth letterforms to case-preserved ASCII (𝐒𝐚𝐫𝐚𝐡
  // 𝐒𝐦𝐢𝐭𝐡 → "Sarah Smith", Ｓａｒａｈ → "Sarah"), which render as legible
  // Latin names to every reader but never matched the ASCII [A-Z][a-z]+ regex —
  // a full real name could be published, de-anonymizing the named person.
  const canon = foldLetterformsKeepCase(text);
  // Each name token allows an optional "Mc"/"Mac" prefix so internal-capital
  // surnames (McNiel, MacArthur) match — the plain [A-Z][a-z]+ shape stops at
  // the second capital, so "Ally McNiel" used to slip through entirely. Mc/Mac
  // brand words (MacBook, McDonald) are kept out of the SAFE set below.
  const re = /\b((?:Ma?c)?[A-Z][a-z]+)\s+((?:Ma?c)?[A-Z][a-z]+)\b/g;
  for (const m of canon.matchAll(re)) {
    const w1 = m[1].toLowerCase();
    const w2 = m[2].toLowerCase();
    if (w1.length < 2 || w2.length < 2) continue;
    if (SAFE_CAPITALIZED_WORDS.has(w1) || SAFE_CAPITALIZED_WORDS.has(w2)) continue;
    if (AMBIGUOUS_WORDS.has(w1) && AMBIGUOUS_WORDS.has(w2)) continue;
    if (SAFE_PROPER_NOUN_BIGRAMS.has(`${w1} ${w2}`)) continue;
    // M-2: a bigram containing a common English title/phrase word is a phrase,
    // not a name — UNLESS the other token is a known given name (keeps "Sarah
    // Park", "Grace Lake" flagged while clearing "Central Park", "Last Night").
    if ((COMMON_TITLE_WORDS.has(w1) || COMMON_TITLE_WORDS.has(w2))
        && !COMMON_NAMES.has(w1) && !COMMON_NAMES.has(w2)) continue;
    return true;
  }
  return false;
}

const IDENTIFYING_PATTERNS = [
  "instagram", "insta", "snapchat", "snap", "tiktok", "twitter",
  "facebook", "linkedin", "phone number", "my number", "text me",
  "call me", "dm me", "follow me", "find me", "look me up",
  "last name", "full name", "school name",
  // Launch-readiness (2026-06-10): removed loose "works at"/"goes to"/"lives
  // in"/"lives on" — literal substrings that false-positive heavily on normal
  // grief writing ("she works at the hospital where we met", "lives in my head
  // rent free now", "he goes to my gym"). index.js's identifyingPhrases already
  // dropped them for the same reason; this aligns the delegated detector and
  // cuts a large false-positive class. "lives at" (street context) + "address"
  // are more specific and kept.
  "lives at", "address",
  // N-15 (2026-06-10 re-review): removed the loose "apartment"/"apt "/"suite "
  // substrings — they false-positived on benign text ("adapt to change", "the
  // suite life", "my apartment is empty now"). Real unit numbers are still
  // caught by the gated Layer-2 regex below (\b(apt|unit|suite|ste)…\d+), which
  // requires a following number.
  "her name is", "his name is", "their name is",
  // NOTE: "named " was previously in this list as a broad keyword and
  // false-positived on legitimate sentences like "she named the dog Rex"
  // or "we named the album X". The careful NAMED_PATTERNS check below
  // (which requires the following token to be capitalized) is strictly
  // better and catches the cases we care about ("she was named Olivia")
  // without the FP surface. Mirror of the Swift removal.
  "zip code", "zipcode",
  "discord", "telegram", "whatsapp", "signal",
  "threads", "bluesky", "reddit",
];

// Two-letter social-platform shorthand (ig:, sc:, fb:) — word-boundary
// anchored so generic English ("dig:", "fab:", "abs.") doesn't false-
// positive. The full names (instagram, snapchat, facebook) are in
// IDENTIFYING_PATTERNS above; this catches the very common shortcut
// syntax `ig: sarahreal` that the keyword list misses because "ig"
// alone is too generic to substring-match.
// Social-handle shorthand: "ig:" / "sc." / "fb-" (separator form) OR the
// natural-language handoff "my ig is sarahreal" / "on ig sarahreal" / "add me on
// sc x" (F-2, 2026-06-12 — the separator-only form missed "my ig is <handle>",
// a common Instagram-handle handoff that de-anonymizes). The second alternative
// requires a following handle-shaped token so plain "follow my ig" with no
// handle still passes.
const SOCIAL_SHORTHAND_RE = /\b(ig|sc|fb)\b\s*[:.\-]|\b(?:my|on|add\s+me\s+on|find\s+me\s+on)\s+(ig|sc|fb)\b\s+(?:is\s+)?[a-z0-9._]{3,}/i;

const RELATIONSHIP_PREFIXES = [
  "my ex ", "my friend ", "my bf ", "my gf ",
  "my boyfriend ", "my girlfriend ", "my sister ", "my brother ",
  "my mom ", "my dad ", "my mother ", "my father ",
  "my coworker ", "my boss ", "my roommate ", "my neighbor ",
  "this girl ", "this guy ", "this boy ", "this man ", "this woman ",
];

const NAMED_PATTERNS = ["named ", "called ", "name is ", "name was "];

const STREET_SUFFIXES = "street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|road|rd|way|place|pl|court|ct|circle|cir|terrace|trail|parkway|pkwy";
const STREET_REGEX = new RegExp(`\\d+\\s+[A-Za-z]+\\s+(${STREET_SUFFIXES})\\b`, 'i');

// Doxxable location-context patterns. These catch the subtle locator
// phrasing that the literal street-suffix / phone / "lives at" rules miss:
//   "he works at chicago mercy hospital"
//   "the cafe above the bodega on 5th and vine"
//   "she goes to UCLA"
//   "from brooklyn"
// Heuristic — some false positives on legitimate "we worked at the same
// hospital" venting. Tighter than letting a doxx with no street number
// through.
const LOCATION_CONTEXT_PATTERNS = [
  // Workplace + capitalized proper-noun anchor (institution / business).
  /\b(works at|worked at|employed at)\s+(the\s+)?[A-Z][A-Za-z'-]+/,
  // Education with named institution / school district.
  /\b(goes to|went to|attends|studies at|enrolled at|graduated from)\s+(the\s+)?[A-Z][A-Za-z'-]+/,
  // Common identifiable-place context — hospital / school / etc. preceded
  // by a locator preposition.
  /\b(at|near|behind|above|across from|next to|in front of)\s+(the\s+)?(hospital|school|university|college|library|station|airport|bodega|cafe|bar|diner|restaurant|coffee shop|gym|church|mosque|temple|synagogue|park|mall|stadium|theater|theatre|hotel|motel|hostel|hospital)\b/i,
  // Cross-street intersection: "on 5th and vine", "at park and 33rd".
  /\b(on|at|near|by)\s+[A-Za-z0-9]+\s+(and|&)\s+[A-Za-z0-9]+\s+(street|st|ave|avenue|blvd|drive|dr)\b/i,
  /\b(corner of|intersection of)\s+[A-Za-z0-9]+\s+(and|&)\s+[A-Za-z0-9]+\b/i,
  // From [City] — top-50ish US population list plus a handful of major
  // international cities. Trimmed to common single-word and two-word
  // entries; long-tail city names are intentionally not enumerated.
  /\b(from|in|near|outside)\s+(new york|brooklyn|manhattan|queens|los angeles|chicago|houston|phoenix|philadelphia|san diego|dallas|austin|seattle|denver|boston|portland|miami|atlanta|nashville|charlotte|detroit|memphis|baltimore|milwaukee|sacramento|kansas city|las vegas|long beach|fresno|oakland|minneapolis|cleveland|tampa|honolulu|new orleans|wichita|raleigh|omaha|tucson|albuquerque|st louis|saint louis|cincinnati|pittsburgh|anchorage|st paul|saint paul|toledo|newark|jersey city|orlando|tulsa|arlington|virginia beach|colorado springs|london|paris|tokyo|berlin|toronto|sydney|melbourne|dublin|madrid|rome|amsterdam|barcelona|mumbai|delhi|beijing|shanghai|mexico city)\b/i,
];

const CRISIS_NUMBERS = [
  "988-273-8255", "9882738255", "988 273 8255",
  "1-800-273-8255", "18002738255", "1 800 273 8255",
  "741741", "741 741",
  "1-800-799-7233", "18007997233",
  "1-800-656-4673", "18006564673",
];

// Confusable map: Cyrillic + Greek lookalikes folded to Latin. Mirror of
// nameConfusableMap in FeedView.swift.
const NAME_CONFUSABLE_MAP = {
  // Cyrillic uppercase
  "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
  "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
  "Ѕ": "S", "Ԁ": "D", "Һ": "H",
  // Cyrillic lowercase (ѕ U+0455 is the perfect "s" lookalike — its absence
  // let a single substituted letter defeat the whole crisis/threat matcher)
  "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
  "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j",
  "ѕ": "s", "ԁ": "d", "һ": "h",
  // Latin script g (U+0261), the standard "g" confusable outside Cyrillic
  "ɡ": "g",
  // Dotless i family (2026-10-07 pentest): Turkish ı (U+0131) is typeable on
  // a standard Turkish layout and renders ≈ "i", but has no NFD decomposition
  // and wasn't mapped — "kıll myself"/"suıcıde" slipped every matcher lane
  // (the no-space fallback even DELETED it as a non-[a-z0-9] char). Fold the
  // lowercase forms and their capitals; İ (U+0130) needs no entry — it
  // lowercases to i + combining dot, which the NFD strip already handles.
  "ı": "i", "Ɨ": "i", "ɨ": "i", "ɩ": "i", "Ɩ": "i",
  // Greek uppercase
  "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
  "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
  // Greek lowercase
  "α": "a", "β": "b", "ε": "e", "ι": "i", "ο": "o", "ρ": "p",
  "τ": "t", "υ": "y", "χ": "x",
};

const NAME_LEET_MAP = {
  "0": "o", "1": "i", "3": "e", "4": "a",
  "5": "s", "7": "t", "8": "b",
  "@": "a", "$": "s",
};

// ============================================================
// Normalization helpers — mirror of canonicalize / aggressiveNormalizeForNameMatch.
// ============================================================

// Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) cover bold, italic,
// script, fraktur, and double-struck letterforms that render as visually
// indistinguishable Latin letters but ship as different code points so
// they slip past the name detector. The block is contiguous and folds
// modularly: each 26-letter run starts at one of the offsets below.
// Enumerating all known starting offsets here is more reliable than NFKC
// (which is invasive and has unwanted side effects on emoji + symbols).
//
// Offsets cover: bold, italic, bold-italic, script, bold-script, fraktur,
// double-struck, bold-fraktur, sans-serif, sans-serif bold, sans-serif
// italic, sans-serif bold-italic, monospace — both upper and lower case.
const MATH_ALPHA_UPPER_OFFSETS = [
  0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538,
  0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670,
];
const MATH_ALPHA_LOWER_OFFSETS = [
  0x1D41A, 0x1D44E, 0x1D482, 0x1D4B6, 0x1D4EA, 0x1D51E, 0x1D552,
  0x1D586, 0x1D5BA, 0x1D5EE, 0x1D622, 0x1D656, 0x1D68A,
];

// Bidi controls + invisible separators that render-as-nothing but split
// tokens. Stripping them BEFORE NFD decompose prevents an attacker from
// fragmenting a flagged name with `J​ohn` (zero-width space splits
// the token before tokenizeAlphanumeric runs) or reversing it with U+202E
// (RTL override flips visual order without changing codepoint sequence).
//
// Built from an explicit codepoint list (rather than a hand-typed literal of
// invisible characters) so the set is reviewable and extendable. All entries
// are BMP, so \uXXXX in the constructed class is sufficient.
const STRIP_INVISIBLE_CODEPOINTS = [
  0x200b, 0x200c, 0x200d, 0x200e, 0x200f, // ZWSP, ZWNJ, ZWJ, LRM, RLM
  0x202a, 0x202b, 0x202c, 0x202d, 0x202e, // bidi embed/override controls
  0x2060,                                 // word joiner
  0x2066, 0x2067, 0x2068, 0x2069,         // bidi isolates
  0xfeff,                                 // zero-width no-break space / BOM
  // 2026-06-01 audit: render-as-nothing separators an attacker can splice
  // into a flagged name with NO visible change, fragmenting the token so the
  // name lookup misses (e.g. `Sa­rah` looks exactly like "Sarah").
  0x00ad,                 // soft hyphen
  0x034f,                 // combining grapheme joiner
  0x061c,                 // arabic letter mark
  0x115f, 0x1160,         // Hangul choseong / jungseong fillers
  0x17b4, 0x17b5,         // Khmer invisible inherent vowels
  0x180e,                 // Mongolian vowel separator
  0x3164,                 // Hangul filler
  0xffa0,                 // halfwidth Hangul filler
];
const STRIP_INVISIBLE_RE = new RegExp(
  "[" +
    STRIP_INVISIBLE_CODEPOINTS.map(
      (cp) => "\\u" + cp.toString(16).padStart(4, "0")
    ).join("") +
    "]",
  "g"
);

// Fold fullwidth digits (U+FF10..U+FF19) to ASCII 0-9. Used by the phone
// heuristic, which counts ASCII \d; without this, a number typed in
// fullwidth digits renders as digits to a human but counts as zero.
function foldFullwidthDigits(s) {
  return s.replace(/[０-９]/g, (d) =>
    String.fromCharCode(d.charCodeAt(0) - 0xfee0)
  );
}

function foldMathAlpha(cp) {
  for (const start of MATH_ALPHA_UPPER_OFFSETS) {
    if (cp >= start && cp <= start + 25) return String.fromCharCode(0x41 + (cp - start));
  }
  for (const start of MATH_ALPHA_LOWER_OFFSETS) {
    if (cp >= start && cp <= start + 25) return String.fromCharCode(0x61 + (cp - start));
  }
  return null;
}

// Case-PRESERVING fold of the two letterform-evasion classes that defeat the
// ASCII [A-Z][a-z] full-name regex: Mathematical Alphanumeric Symbols
// (U+1D400+) and fullwidth Latin (U+FF21..FF5A). Unlike canonicalize (which
// lowercases for dictionary lookup), this keeps case so the two-capitalized-
// words shape still matches "𝐉𝐨𝐡𝐧 𝐌𝐚𝐫𝐜𝐡𝐞𝐭𝐭𝐢" → "John Marchetti". F-1.
function foldLetterformsKeepCase(text) {
  if (!text) return "";
  let result = "";
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    if (cp >= 0xFF21 && cp <= 0xFF3A) { result += String.fromCodePoint(cp - 0xFEE0); continue; }
    if (cp >= 0xFF41 && cp <= 0xFF5A) { result += String.fromCodePoint(cp - 0xFEE0); continue; }
    if (cp >= 0x1D400 && cp <= 0x1D7FF) {
      const folded = foldMathAlpha(cp);
      if (folded) { result += folded; continue; }
    }
    result += ch;
  }
  return result;
}

function canonicalize(text) {
  if (!text) return "";
  // Strip invisible separators + bidi controls before normalization so
  // an evader can't fragment tokens or reverse visual order to slip past
  // the detector.
  const stripped = text.replace(STRIP_INVISIBLE_RE, "");
  const decomposed = stripped.normalize("NFD");
  let result = "";
  // Iterate code points (handles surrogate pairs correctly).
  for (const ch of decomposed) {
    const cp = ch.codePointAt(0);
    // Combining marks (U+0300..U+036F) — drop after NFD decompose.
    if (cp >= 0x0300 && cp <= 0x036F) continue;
    // Fullwidth uppercase (U+FF21..U+FF3A) → ASCII.
    if (cp >= 0xFF21 && cp <= 0xFF3A) {
      result += String.fromCodePoint(cp - 0xFEE0);
      continue;
    }
    // Fullwidth lowercase (U+FF41..U+FF5A) → ASCII.
    if (cp >= 0xFF41 && cp <= 0xFF5A) {
      result += String.fromCodePoint(cp - 0xFEE0);
      continue;
    }
    // Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) → ASCII letter.
    // Covers bold/italic/script/fraktur/double-struck/sans-serif/monospace
    // letterforms that look identical to Latin but ship as separate code
    // points (e.g. `𝐉𝐨𝐡𝐧` renders as "John" but bypasses the name match
    // without folding).
    if (cp >= 0x1D400 && cp <= 0x1D7FF) {
      const folded = foldMathAlpha(cp);
      if (folded) {
        result += folded;
        continue;
      }
    }
    if (NAME_CONFUSABLE_MAP[ch]) {
      result += NAME_CONFUSABLE_MAP[ch];
      continue;
    }
    result += ch;
  }
  return result.toLowerCase();
}

// Same combining-mark + invisible-separator strip as canonicalize, but
// preserves case and does NOT fold confusables / fullwidth / math-alpha.
// Used to tokenize text in Layers 4 / 4.5: an attacker who inserts
// standalone combining marks (e.g. `S̶arah` = S + U+0336 + arah) fragments
// the token under the default `\p{L}\p{N}` split because combining marks
// are Mn category. Stripping them first re-merges the token so the name
// lookup sees `Sarah` as a single capitalized word.
function stripCombiningMarksKeepCase(text) {
  if (!text) return "";
  const stripped = text.replace(STRIP_INVISIBLE_RE, "");
  const decomposed = stripped.normalize("NFD");
  let result = "";
  for (const ch of decomposed) {
    const cp = ch.codePointAt(0);
    if (cp >= 0x0300 && cp <= 0x036F) continue;
    result += ch;
  }
  return result;
}

function aggressiveNormalizeForNameMatch(text) {
  const canon = canonicalize(text);
  let deLeet = "";
  for (const ch of canon) {
    deLeet += NAME_LEET_MAP[ch] || ch;
  }
  // Collapse single-letter separator chains.
  // Pattern: word boundary, single letter, then 1+ runs of (separator+ then
  // single letter), bounded by word boundary. Single-character classes only,
  // no nested quantifiers — backtracking-safe.
  return deLeet.replace(/\b[a-z](?:[.\-_ ]+[a-z])+\b/g, (match) => {
    return match.replace(/[.\-_ ]+/g, "");
  });
}

// Token splitter: equivalent to Swift's
// `text.components(separatedBy: CharacterSet.alphanumerics.inverted)`.
// JS regex `\W` in Unicode mode (`u` flag) matches non-letter/digit/underscore;
// we want non-alphanumeric, so split on any sequence of non-letter/non-digit
// that includes underscore. Use `\P{L}` and `\P{N}` via a unicode-property class.
function tokenizeAlphanumeric(text) {
  return text.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0);
}

function sentenceStarters(text) {
  const starters = new Set();
  for (const sentence of text.split(/[.!?\n]/)) {
    const trimmed = sentence.trim();
    if (!trimmed) continue;
    const tokens = tokenizeAlphanumeric(trimmed);
    if (tokens.length > 0) starters.add(tokens[0]);
  }
  return starters;
}

function isUpperFirst(word) {
  if (!word) return false;
  // First code point — not first UTF-16 unit (handles emoji-prefixed tokens
  // even though they're non-alphanumeric and won't appear in tokens here).
  const first = String.fromCodePoint(word.codePointAt(0));
  return first === first.toUpperCase() && first !== first.toLowerCase();
}

// ============================================================
// Shared URL / link detector (T-10, 2026-06-11).
//
// Previously there were THREE URL detectors that drifted: this module's inline
// Layer-1 regexes (the HOLD decision), index.js `urlPatterns`/`containsURL`
// (the pii-vs-abuse_link LABEL decision), and index.js SPAM_PATTERNS (posts-
// only). The first two disagreed (e.g. youtu.be held-but-mislabeled). This is
// now the single source — Layer-1 below uses it, and index.js imports it for
// the label decision, so the hold and the label can never disagree again.
//
// Country-code TLDs (.be/.ru/.it/…) are intentionally NOT matched generically:
// they collide with ordinary prose ("maybe.be", "split.it") and the false-
// positive cost on a grief app outweighs catching a bare cc-TLD domain. The
// few cc-TLD link forms that matter in practice (youtu.be, t.me) are listed
// explicitly.
// ============================================================
const URL_REGEXES = [
  /https?:\/\//i,
  /\bwww\.[a-z]/i,
  /\b[a-z0-9-]+\.(com|net|org|io|co|app|xyz|gg|tv|me|info|link)\b/i,
  /\b(cash\.app|linktr\.ee|bit\.ly|tinyurl|youtu\.be|t\.me)\b/i,
];

function containsURL(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  return URL_REGEXES.some((re) => re.test(text));
}

// ============================================================
// Main detector — mirror of containsNameOrIdentifyingInfo in FeedView.swift.
// ============================================================

// Hard input-length ceiling for the detector (F1, 2026-06-11 security
// re-review). The separator-collapse normalization and the phone digit-strip
// chain below are O(n²) in input length, so an unbounded string could burn
// seconds of function CPU per event. Posts/replies are capped at 2000/500 chars
// at the RULES layer, but the moderation-only triggers (onPostUpdated /
// onReplyUpdated / containsPII) invoke this with no server-side guard and would
// rely entirely on that cap. Truncating here makes the detector self-bounding
// regardless of caller or a future rule regression — any PII signal worth
// holding on appears well within the first 2000 chars.
const DETECTOR_MAX_LEN = 2000;

function containsNameOrIdentifyingInfo(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  if (text.length > DETECTOR_MAX_LEN) text = text.slice(0, DETECTOR_MAX_LEN);
  const lowered = text.toLowerCase();

  // ----- Original chain -----

  for (const pattern of IDENTIFYING_PATTERNS) {
    if (lowered.includes(pattern)) return true;
  }

  // Social-shorthand label syntax (ig: / sc: / fb: with optional space +
  // colon/period/dash). Word-boundary anchored so "dig: deeper", "abs.",
  // "fab-" don't false-positive.
  if (SOCIAL_SHORTHAND_RE.test(text)) return true;

  // @handle
  if (/@[a-zA-Z]/.test(text)) return true;

  // Spelled-out email (#2 fuzz, 2026-06-11): a literal email ("x@gmail.com") is
  // already caught by the URL layer (the "gmail.com" host trips containsURL),
  // but the obfuscated "name at provider dot com" form has no literal dot/@ and
  // slipped through. Requires a known TLD word after "dot" so ordinary prose
  // ("good at math, full stop") doesn't trip. Mirror in FeedView.swift.
  if (/\b[a-z0-9._%+-]+\s+at\s+[a-z0-9][a-z0-9.\s-]*\s+dot\s+(com|net|org|io|co|edu|gov|me|gg|us|uk|ca)\b/i.test(text)) return true;

  // Possessive name. N-17 launch tuning (2026-06-11): a LONE FIRST-name
  // possessive ("Jessica's laugh") is allowed — a bare first name identifies
  // no one and naming a feeling/memory is the modal breakup post. A LAST-name
  // possessive ("Johnson's") is more identifying and still held.
  const possessiveRegex = /\b([A-Z][a-z]{2,})'s\b/g;
  for (const match of text.matchAll(possessiveRegex)) {
    const name = match[1].toLowerCase();
    if (COMMON_LAST_NAMES.has(name) && name.length >= 3 && !AMBIGUOUS_WORDS.has(name)) return true;
  }

  // Relationship prefix + capitalized first word. N-17 (2026-06-11): "my ex
  // Sarah" (prefix + bare FIRST name) is allowed; a prefix + LAST name ("my ex
  // Johnson") stays held, and a prefix + FULL name ("my ex Sarah Johnson") is
  // caught by looksLikeFullName below.
  for (const prefix of RELATIONSHIP_PREFIXES) {
    const idx = lowered.indexOf(prefix);
    if (idx === -1) continue;
    const after = text.slice(idx + prefix.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (isUpperFirst(firstToken)
        && COMMON_LAST_NAMES.has(firstToken.toLowerCase()) && firstToken.length >= 3) return true;
  }

  // "named X" / "called X" / "name is X". N-17: same — a following bare FIRST
  // name is allowed; a LAST name is held; a FULL name is caught below.
  for (const pattern of NAMED_PATTERNS) {
    const idx = lowered.indexOf(pattern);
    if (idx === -1) continue;
    const after = text.slice(idx + pattern.length).trim();
    const firstToken = after.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0)[0];
    if (!firstToken) continue;
    if (isUpperFirst(firstToken)
        && COMMON_LAST_NAMES.has(firstToken.toLowerCase()) && firstToken.length >= 3) return true;
  }

  // Street address.
  if (STREET_REGEX.test(text)) return true;

  // Doxxable location-context (works at X, the cafe above the bodega on
  // 5th and vine, from brooklyn, etc.). Heuristic; some false positives
  // on legitimate venting that name a workplace/city without targeting a
  // specific person. Caught here, the post-trigger deletes it server-
  // side; if it turns out to be over-aggressive we trim the patterns.
  for (const re of LOCATION_CONTEXT_PATTERNS) {
    if (re.test(text)) return true;
  }

  // N-17 (2026-06-11): the mid-sentence LONE-FIRST-NAME detector was removed —
  // a bare first name ("I miss John") is the modal breakup post and identifies
  // no one. Full names are still caught by looksLikeFullName below (the two-
  // capitalized-words shape), and lone LAST names by the canonicalized
  // name-layers further down. Contact info / addresses / handles are unchanged.

  // Full-name shape: two consecutive Capitalized words ("Vera Marchetti").
  if (looksLikeFullName(text)) return true;

  // 10+ digits → phone number heuristic.
  // Strip invisible separators (so `5​5​5…` collapses to a contiguous run)
  // and fold fullwidth digits U+FF10..U+FF19 → ASCII (so a phone typed in
  // fullwidth digits, `５５５１２３４５６７`, is counted by the \d heuristic
  // below instead of slipping past as zero ASCII digits). 2026-06-01 audit.
  let digitStripped = foldFullwidthDigits(text.replace(STRIP_INVISIBLE_RE, ""));
  for (const num of CRISIS_NUMBERS) {
    digitStripped = digitStripped.split(num).join("");
  }
  // M-2 (2026-06-08 audit): remove breakup-timeline number lists BEFORE the
  // separator-collapse below, so they don't merge into one long run that
  // survives the year/small-number strips and inflates the digit count past
  // the phone threshold. Targeted so real phone groupings — which mix 2–4
  // digit groups — are untouched (the second pattern needs 4+ consecutive
  // 1–3 digit tokens; a phone's 4-digit exchange/line groups break that run):
  //   - 2+ consecutive 4-digit year tokens: "we dated 2019 2020 2021 2022 2023"
  //   - 4+ consecutive 1–3 digit tokens:    "scores were 100 95 88 76 65 54 …"
  // A real international phone ("+44 20 7946 0958") matches neither and still
  // trips the >=10-digit check below.
  digitStripped = digitStripped
    .replace(/\b(?:19|20)\d\d(?:\s+(?:19|20)\d\d)+\b/g, " ")
    .replace(/\b\d{1,3}(?:\s+\d{1,3}){3,}\b/g, " ");
  // Collapse phone-format separators between digits so a formatted phone
  // like `(555) 123-4567` survives the date/year/small-number strips
  // below. Without this, `\b\d{1,3}\b` peels `555`, `123` and `\b\d{4,5}\b`
  // peels `4567` because parens/space/dash sit at word boundaries around
  // each digit chunk — total digit count goes to zero. Lookahead-anchored
  // so a separator at end of text (e.g., trailing `.`) doesn't gobble.
  // Plain whitespace IS included in the class because users write phones
  // as `555 123 4567`; the false-positive risk (a sentence with 10+ digits
  // separated only by single spaces) is acceptable on a heartbreak app.
  digitStripped = digitStripped.replace(/(\d)[-.\s()]+(?=\d)/g, "$1");
  digitStripped = digitStripped
    .replace(/\d{1,2}[:/]\d{2}/g, "")
    .replace(/\b\d{4,5}\b/g, "")
    .replace(/\b\d{1,3}\b/g, "")
    .replace(/\$[\d,]+/g, "")
    .replace(/\d{1,2}\/\d{1,2}\/\d{2,4}/g, "");
  const digitCount = (digitStripped.match(/\d/g) || []).length;
  if (digitCount >= 10) return true;

  // ----- Evasion-hardening layers (mirror of Swift Layers 1-6) -----

  // Layer 1: URL / social-link detection (shared detector, T-10).
  if (containsURL(text)) return true;

  // Layer 2: Apartment / unit / suite numbers.
  if (/\b(apt|unit|suite|ste)\.?\s*#?\s*\d+[a-z]?\b/i.test(text)) return true;
  if (/#\s*\d{1,4}[a-z]?\b/.test(text)) return true;

  // Layer 3: Dotted initials with relationship context — "my ex J.S."
  for (const prefix of RELATIONSHIP_PREFIXES) {
    const idx = lowered.indexOf(prefix);
    if (idx === -1) continue;
    const window = text.slice(idx + prefix.length, idx + prefix.length + 40);
    if (/\b[A-Z]\.[A-Z]\.?/.test(window)) return true;
  }

  // Layer 4: Per-token canonicalize-then-name-lookup.
  // Tokenize the COMBINING-MARK-STRIPPED form of the text, not the raw
  // text. Standalone combining marks (U+0300-U+036F) are Mn category and
  // get treated as token separators under `\p{L}\p{N}` split — an
  // attacker writing `S̶arah` (= S + U+0336 + arah) fragments the token
  // into ['S', 'arah'] under raw tokenization, and neither piece matches
  // a name. Stripping combining marks (case-preserving) before split
  // collapses the token to `Sarah` so the name lookup sees it.
  const canonical = canonicalize(text);
  const canonStarters = sentenceStarters(canonical);
  const layer4Words = stripCombiningMarksKeepCase(text)
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w.length > 0);
  for (const word of layer4Words) {
    const canonWord = canonicalize(word);
    if (canonWord.length < 2) continue;
    if (AMBIGUOUS_WORDS.has(canonWord)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(canonWord)) continue;
    const isFirst = COMMON_NAMES.has(canonWord);
    const isLast = COMMON_LAST_NAMES.has(canonWord) && canonWord.length >= 3;
    if (!isFirst && !isLast) continue;
    // Whether the raw token differs from its canonical form (= obfuscation:
    // confusables / leet / fullwidth / math-alpha / combining marks).
    const isEvasion = word.toLowerCase() !== canonWord;
    // Require an uppercase-first token to count as a name — UNLESS it's an
    // evasion token (F-1, 2026-06-12). Math-alphanumeric letters carry NO
    // Unicode case mapping, so isUpperFirst("𝐒𝐦𝐢𝐭𝐡") is false and the token
    // was skipped here before its evasion was ever evaluated. Evasion tokens
    // bypass the raw-case gate (their canonical form is the real signal).
    if (!isUpperFirst(word) && !isEvasion) continue;
    // Sentence-starter exemption applies only to legit-prose tokens.
    // If canonicalize had to fold confusables / fullwidth / accents to
    // reach the name (i.e. the original lowercased token differs from the
    // canonical token), that's evasion and the starter exemption no
    // longer applies — "Mіchael" at the start of a sentence is an attack,
    // not a casual capitalization. Mirror of the Swift Layer 4 fix.
    // (isEvasion computed above, before the raw-case gate.)
    // N-17 (2026-06-11): a PLAIN lone FIRST name is allowed (the dominant FP —
    // "I miss John" is the modal breakup post and identifies no one). An
    // OBFUSCATED first name (confusables / leet / fullwidth / combining-mark =
    // isEvasion) is still HELD: deliberately evading the name filter signals
    // intent to identify-and-hide. LAST names are always held; FULL names are
    // caught by looksLikeFullName + the last-name component.
    if (isFirst && !isLast && !isEvasion) continue;
    // B-1 (2026-06-16): the sentence-starter exemption must NOT spare a known
    // LAST name. It was added to protect legit first-name sentence subjects
    // ("Sarah left me"), but without the isFirst/!isLast gate it also exempted
    // surnames as sentence subjects ("Garcia broke my heart") — a real-name
    // leak straight through the de-anon perimeter. (For pure first names this
    // is now redundant with the line above; kept explicit to mirror Swift.)
    if (!isEvasion && isFirst && !isLast && canonStarters.has(canonWord)) continue;
    return true;
  }

  // Layer 4.5: Reversed-token name lookup. The canonicalize step strips
  // bidi-override characters (so a render-time visual flip can't slip
  // through), but doesn't try a literal codepoint reversal — an attacker
  // who writes "haraS" as plain ASCII (no bidi codepoints) sails through
  // every prior layer because the forward token doesn't match any name.
  // Reverse each canonicalized token and re-check against the name sets.
  // Length floor of 4 keeps the false-positive budget tight: short names
  // reversed (e.g. "ana" → "ana", "rae" → "ear") collide with common
  // English fragments. Palindromes are skipped since the forward layers
  // would have already had a chance. Ambiguous / safe lists apply to the
  // reversed form too — if the reversed string is a common word, it's
  // more likely an incidental collision than evasion.
  // Uses the same combining-mark-stripped tokenization as Layer 4 so
  // `S̶mith` (combining-mark fragmentation) is reversed as `htimS`.
  for (const word of layer4Words) {
    const canonWord = canonicalize(word);
    if (canonWord.length < 4) continue;
    const reversed = [...canonWord].reverse().join("");
    if (reversed === canonWord) continue; // palindrome — forward layers cover
    if (AMBIGUOUS_WORDS.has(reversed)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(reversed)) continue;
    // N-17 (2026-06-11): a REVERSED name is by definition an evasion attempt
    // (nobody writes a name backwards casually), so first names still flag here
    // — same rationale as the obfuscation gate in Layer 4.
    const isFirstRev = COMMON_NAMES.has(reversed);
    const isLastRev = COMMON_LAST_NAMES.has(reversed) && reversed.length >= 3;
    if (isFirstRev || isLastRev) return true;
  }

  // Layer 5: Whole-text aggressive normalization.
  const aggressive = aggressiveNormalizeForNameMatch(text);
  const canonicalTokens = new Set(tokenizeAlphanumeric(canonical));
  const aggressiveTokens = tokenizeAlphanumeric(aggressive).filter((t) => t.length >= 2);
  for (const token of aggressiveTokens) {
    if (AMBIGUOUS_WORDS.has(token)) continue;
    if (SAFE_CAPITALIZED_WORDS.has(token)) continue;
    // N-17 (2026-06-11): Layer 5 only fires on tokens that emerge AFTER
    // aggressive normalization but are NOT in the plain canonical tokenization
    // (the `canonicalTokens.has` skip below) — i.e. spaced/separated names like
    // "j o h n", which is itself an evasion vector. So first names still flag
    // here, consistent with the obfuscation gate in Layer 4.
    const isName = COMMON_NAMES.has(token) || (COMMON_LAST_NAMES.has(token) && token.length >= 3);
    if (!isName) continue;
    if (canonicalTokens.has(token)) continue;
    return true;
  }

  // Layer 6: Identifying-pattern keywords on canonicalized text.
  for (const pattern of IDENTIFYING_PATTERNS) {
    if (canonical.includes(pattern)) return true;
  }

  return false;
}


// ── likelyFirstName (owner decision 2026-10-29) ──────────────────────────────
// A SOFT signal, never a hold: "does this text mention a likely first name?"
// Drives (a) the non-blocking compose nudge on iOS + web, (b) the website
// featuring exclusion (publicFeed / sitemap / share-page indexability /
// webFeatured guard), (c) the admin "possible name" badge. Bare first names
// stay ALLOWED in the app (N-17 launch tuning) — this only says "a first name
// is here". Rule: a token whose canonicalized lowercase form is in COMMON_NAMES
// and not in AMBIGUOUS_WORDS / SAFE_CAPITALIZED_WORDS, and that is either
// Capitalized (or a Capitalized possessive, "Sarah's") in the original text,
// or lowercase but directly after a relationship prefix ("my ex sam").
// Mirror: ContentModeration.swift likelyFirstName — pinned by detector-parity.
function likelyFirstName(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  if (text.length > DETECTOR_MAX_LEN) text = text.slice(0, DETECTOR_MAX_LEN);
  const canon = foldLetterformsKeepCase(text).replace(DONT_CONTRACTION_RE, " ");
  const capRe = /\b([A-Z][a-z]+)\b/g;
  for (const m of canon.matchAll(capRe)) {
    const w = m[1].toLowerCase();
    if (w.length < 2) continue;
    if (NUDGE_ONLY_NAMES.has(w)) return true;
    if (!COMMON_NAMES.has(w)) continue;
    if (AMBIGUOUS_WORDS.has(w) || SAFE_CAPITALIZED_WORDS.has(w)) continue;
    return true;
  }
  const lowered = canon.toLowerCase();
  for (const prefix of RELATIONSHIP_PREFIXES) {
    let idx = lowered.indexOf(prefix);
    while (idx !== -1) {
      const tok = lowered.slice(idx + prefix.length).split(/[^a-z]+/).filter((t) => t.length > 0)[0];
      if (tok && NUDGE_ONLY_NAMES.has(tok)) return true;
      if (tok && COMMON_NAMES.has(tok) && !AMBIGUOUS_WORDS.has(tok)) return true;
      idx = lowered.indexOf(prefix, idx + prefix.length);
    }
  }
  return false;
}

module.exports = {
  containsNameOrIdentifyingInfo,
  likelyFirstName,
  containsURL,
  canonicalize,
  aggressiveNormalizeForNameMatch,
  // Exposed for tests / future composition.
  COMMON_NAMES,
  COMMON_LAST_NAMES,
  AMBIGUOUS_WORDS,
  SAFE_CAPITALIZED_WORDS,
  NUDGE_ONLY_NAMES,
};
