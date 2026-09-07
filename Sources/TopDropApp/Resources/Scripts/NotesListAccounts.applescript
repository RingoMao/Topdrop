on run argv
    with timeout of 10 seconds
    tell application "Notes"
        set accountRows to {}
        repeat with currentAccount in every account
            set accountIdentifier to (id of currentAccount) as text
            set accountName to (name of currentAccount) as text
            set accountIsUpgraded to upgraded of currentAccount
            set end of accountRows to {accountIdentifier, accountName, accountIsUpgraded}
        end repeat
        return accountRows
    end tell
    end timeout
end run
