on findFolderByID(parentObject, requestedID)
    with timeout of 10 seconds
        tell application "Notes"
            repeat with childFolder in every folder of parentObject
                if ((id of childFolder) as text) is requestedID then return contents of childFolder
                set foundFolder to my findFolderByID(childFolder, requestedID)
                if foundFolder is not missing value then return foundFolder
            end repeat
        end tell
    end timeout
    return missing value
end findFolderByID

on noteRow(theNote, folderIsShared)
    with timeout of 10 seconds
    tell application "Notes"
        set noteIdentifier to (id of theNote) as text
        set noteTitle to "Untitled"
        try
            set noteTitle to (name of theNote) as text
        end try
        try
            set notePlaintext to (plaintext of theNote) as text
        on error
            error "Incomplete note body" number -1700
        end try
        try
            set createdAt to creation date of theNote
            set modifiedAt to modification date of theNote
        on error
            error "Incomplete note dates" number -1700
        end try
        set noteIsLocked to true
        try
            set noteIsLocked to password protected of theNote
        end try
        set noteIsShared to true
        try
            set noteIsShared to shared of theNote
        end try
        set attachmentCount to 1
        try
            set attachmentCount to count of attachments of theNote
        end try
        return {noteIdentifier, noteTitle, notePlaintext, createdAt, modifiedAt, noteIsLocked, noteIsShared, attachmentCount, folderIsShared}
    end tell
    end timeout
end noteRow

on run argv
    set requestedAccountID to (item 1 of argv) as text
    set requestedFolderID to (item 2 of argv) as text
    set requestedHTML to (item 3 of argv) as text
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

        set targetFolder to my findFolderByID(targetAccount, requestedFolderID)
        if targetFolder is missing value then error "Notes folder not found" number -1728
        if shared of targetFolder then error "Shared folders are read-only in TopDrop" number -10006

        set createdNote to make new note at targetFolder with properties {body:requestedHTML}
        return my noteRow(createdNote, shared of targetFolder)
    end tell
    end timeout
end run
