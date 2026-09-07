on appendFolders(parentObject, parentPath, folderRows, seenIDs)
    with timeout of 10 seconds
        tell application "Notes"
            repeat with currentFolder in every folder of parentObject
                set folderIdentifier to (id of currentFolder) as text
                if seenIDs does not contain folderIdentifier then
                    set end of seenIDs to folderIdentifier
                    set folderName to (name of currentFolder) as text
                    set folderPath to parentPath & folderName
                    set folderIsShared to shared of currentFolder
                    set end of folderRows to {folderIdentifier, folderName, folderIsShared, folderPath}
                    my appendFolders(currentFolder, folderPath & "/", folderRows, seenIDs)
                end if
            end repeat
        end tell
    end timeout
end appendFolders

on run argv
    set requestedAccountID to (item 1 of argv) as text
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

        set folderRows to {}
        set seenIDs to {}
        my appendFolders(targetAccount, "", folderRows, seenIDs)
        return folderRows
    end tell
    end timeout
end run
