import Foundation

/// The banks Bookkeeper reads with no teaching, from public format docs
/// (`_Research/2026-10-20-bank-spending-market-research.md` §3). Header strings are
/// unverified against real exports — matching is case/spacing-blind, and any drift
/// falls through to the mapping sheet rather than mis-parsing.
public enum BuiltInRecipes {

    public static let chaseCard = ImportRecipe(
        id: "chase-card", name: "Chase card",
        headerFingerprint: ["Card", "Transaction Date", "Post Date", "Description", "Category",
                            "Type", "Amount", "Memo"],
        dateColumn: 1, dateFormat: "MM/dd/yyyy", descriptionColumn: 3,
        amount: .signed(column: 6, moneyOutIsNegative: true),
        bankCategoryColumn: 4, bankTypeColumn: 5, cardColumn: 0)

    public static let chaseChecking = ImportRecipe(
        id: "chase-checking", name: "Chase checking",
        headerFingerprint: ["Details", "Posting Date", "Description", "Amount", "Type", "Balance",
                            "Check or Slip #"],
        dateColumn: 1, dateFormat: "MM/dd/yyyy", descriptionColumn: 2,
        amount: .signed(column: 3, moneyOutIsNegative: true))

    /// A summary block sits above the header; amounts carry thousands commas.
    public static let bankOfAmericaChecking = ImportRecipe(
        id: "bofa-checking", name: "Bank of America checking",
        headerFingerprint: ["Date", "Description", "Amount", "Running Bal."],
        skipRowsUntilHeader: true,
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1,
        amount: .signed(column: 2, moneyOutIsNegative: true))

    /// No header: date, amount, `*`, empty, description.
    public static let wellsFargo = ImportRecipe(
        id: "wells-fargo", name: "Wells Fargo", columnCount: 5,
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 4,
        amount: .signed(column: 1, moneyOutIsNegative: true))

    public static let capitalOne = ImportRecipe(
        id: "capital-one", name: "Capital One",
        headerFingerprint: ["Transaction Date", "Posted Date", "Card No.", "Description", "Category",
                            "Debit", "Credit"],
        dateColumn: 0, dateFormat: "yyyy-MM-dd", descriptionColumn: 3,
        amount: .split(debitColumn: 5, creditColumn: 6), bankCategoryColumn: 4, cardColumn: 2)

    /// Charges positive.
    public static let amex = ImportRecipe(
        id: "amex", name: "American Express",
        headerFingerprint: ["Date", "Description", "Card Member", "Account #", "Amount"],
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1,
        amount: .signed(column: 4, moneyOutIsNegative: false), cardColumn: 3)

    /// Debit unsigned, credit with a minus — `.split` ignores both signs.
    public static let citi = ImportRecipe(
        id: "citi", name: "Citi",
        headerFingerprint: ["Date", "Description", "Debit", "Credit"],
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1,
        amount: .split(debitColumn: 2, creditColumn: 3))

    /// Purchases positive.
    public static let discover = ImportRecipe(
        id: "discover", name: "Discover",
        headerFingerprint: ["Trans. Date", "Post Date", "Description", "Amount", "Category"],
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 2,
        amount: .signed(column: 3, moneyOutIsNegative: false), bankCategoryColumn: 4)

    /// Purchases positive; a clean `Merchant` column beside the raw `Description`.
    public static let appleCard = ImportRecipe(
        id: "apple-card", name: "Apple Card",
        headerFingerprint: ["Transaction Date", "Clearing Date", "Description", "Merchant", "Category",
                            "Type", "Amount (USD)", "Purchased By"],
        dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 2,
        amount: .signed(column: 6, moneyOutIsNegative: false),
        bankCategoryColumn: 4, bankMerchantColumn: 3, bankTypeColumn: 5)

    public static let all = [chaseCard, chaseChecking, bankOfAmericaChecking, wellsFargo, capitalOne,
                             amex, citi, discover, appleCard]
}
