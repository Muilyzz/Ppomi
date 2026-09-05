// The bank apps: how to open each on the mirrored phone and which OCR row is an account. am.py APPS, same order.
import Foundation

struct AppConfig {
    let key: String
    let title: String           // "KB스타뱅킹"
    let search: String          // Spotlight term (ASCII)
    let account: String         // regex: the OCR row that is an account
    var homeLabel: String? = nil   // tap the icon under this label on home page 1 instead of Spotlight
    var expand: String? = nil      // a word to tap once open (KB's home collapses extras under '더보기')
    var list: String? = nil        // a control that opens the full account list
    var tx: String? = nil          // the home row to tap for the transaction list (first match)
    var txpage: String? = nil      // text only the transaction list has (default: 카카오 '13:06 #' rows)
    var home: String? = nil        // text only the home screen has — absent after opening → tap back
    var scrollY = 0.5              // where the wheel scrolls (KB's web list only moves with the pointer over the rows)
}

enum Apps {
    static let all: [AppConfig] = [
        AppConfig(key: "KB", title: "KB스타뱅킹", search: "kb", account: #"\(\d{4}\)|\d{6}-\d{2}-\d{6}"#, expand: "^더보기", list: "내 계좌 전체보기",
                  tx: "^KB국민ONE통장", txpage: "거래내역조회", home: "내 계좌 전체보기|나의 총 자산|이번 주 카드결제", scrollY: 0.7),
        AppConfig(key: "KBANK", title: "케이뱅크", search: "kbank", account: "통장|계좌|박스|입출금|적금|예금|청약", homeLabel: "케이뱅크"),
        // 카카오뱅크 debit card = the user's daily spending; its 입출금통장 거래내역 is the transaction source (자동로그인 needed)
        AppConfig(key: "KAKAO", title: "카카오뱅크", search: "kakaobank", account: "통장|입출금|세이프박스|적금|모임|예금", tx: "통장", home: "다른금융계좌|홈 혜택"),
        // Toss with 비밀번호 인증 1단계 shows every linked bank/card on its 자산 tab without a PIN. Its rows repeat other
        // banks' accounts, so totals are reported per app, never summed across apps.
        AppConfig(key: "TOSS", title: "토스", search: "toss", account: "통장|계좌|뱅크|은행|입출금|적금|예금|청약"),
    ]
    static let api = ["TOSSINVEST"]                      // no phone needed
    static func config(_ key: String) -> AppConfig? { all.first { $0.key == key } }
}
