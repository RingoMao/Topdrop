on run argv
    set requestedAccountID to (item 1 of argv) as text
    set requestedFolderName to (item 2 of argv) as text
    with timeout of 10 seconds
    tell application "Notes"
        set targetAccount to missing value
        repeat with currentAccount in every account
            if ((id of currentAccount) as text) is requestedAccountID then
                set targetAccount to currentAccount
                exit repeat
            end if
        end repeat
        if targetAccount is missing value then error "Notes account not found" number -1728

        set targetFolder to missing value
        repeat with currentFolder in every folder of targetAccount
            if ((name of currentFolder) as text) is requestedFolderName then
                set targetFolder to currentFolder
                exit repeat
            end if
        end repeat
        if targetFolder is missing value then
            set targetFolder to make new folder at targetAccount with properties {name:requestedFolderName}
        end if

        return {(id of targetFolder) as text, (name of targetFolder) as text, shared of targetFolder}
    end tell
    end timeout
end run
