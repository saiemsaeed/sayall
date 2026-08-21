# SayAll two-speaker recording scripts

Record each entry as a separate WAV with only the named character speaking. Read verbatim_reference exactly, including intentional fillers and repetitions. Do not perform both characters in one recording.

**Total:** 2399 normalized verbatim words across 16 separate recordings.

## Maya

### maya-project-introduction

Save as: `maya-project-introduction.wav` · Category: `everyday` · 138 words

I started the Lantern project because our neighborhood archive had boxes of photographs that nobody could search. Every envelope had a handwritten label, but the labels used different dates, street names, and family names. My first goal is simple. I want a volunteer to open the desktop application, describe one photograph in ordinary language, and save that description without learning a complicated catalog system. This morning I reviewed the first twenty entries and found three duplicated addresses. I am going to ask Daniel to merge those records after I confirm that the photographs really show the same building. Before lunch I also need to email the archive committee, explain what we changed, and invite them to test the new search screen on Friday. If the test goes well, we can begin scanning the next box on Monday morning.

### maya-committee-email

Save as: `maya-committee-email.wav` · Category: `everyday` · 149 words

Please draft an email to the archive committee with the subject Lantern pilot update. Tell them that the import completed successfully and that all one hundred and eighty four public records are available in the test library. Explain that seven records still need a date review and that two photographs have uncertain street names. Ask committee members not to correct those entries until they have checked the paper register. Invite everyone to a forty minute review session at three thirty on Friday the eighteenth. The session will take place in the second floor reading room, and a video link will be available for anyone joining from home. Mention that no private donor records are part of this pilot. End by thanking Priya Shah for checking the image licenses and Daniel Brooks for preparing the recovery instructions. Please use a friendly tone and ask recipients to reply by Wednesday evening.

### maya-design-reflection

Save as: `maya-design-reflection.wav` · Category: `long_form` · 172 words

When we designed the first search screen, I assumed that volunteers would begin with a person or a street name. The observation sessions showed something different. Most people began with a memory, such as the bakery beside the old cinema or the winter when the river froze. Those memories did not match a single database field. We changed the design so a person can enter a whole phrase and then narrow the results by decade, location, or collection. That choice made the interface easier, but it also exposed inconsistent descriptions in the archive. One volunteer wrote Saint Anne Street while another wrote St Anne's Street, and both were referring to the same place. We decided not to rewrite historical labels automatically. Instead, Lantern preserves the original wording and attaches a reviewed search term. This approach takes more work, yet it keeps the record honest and still helps people find related material. The next design review should examine whether that distinction is clear to someone using the application for the first time.

### maya-launch-story

Save as: `maya-launch-story.wav` · Category: `long_form` · 170 words

On the morning of the public demonstration, I arrived early and found a handwritten note taped to the archive door. A retired teacher named Elena had heard about the project and brought a photograph of a street parade from nineteen sixty three. The picture showed a banner, several shop fronts, and dozens of people, but nobody had written the location on the back. Elena remembered that the parade passed a pharmacy owned by her uncle. We searched Lantern for the uncle's surname, compared three storefront photographs, and identified the corner as Willow Avenue and North Market Road. The discovery was not dramatic in a technical sense, yet it showed exactly why the project mattered. A description entered by one volunteer helped another person recover the context of a family photograph. During the demonstration I want to tell this story without claiming that the software solved the mystery alone. Elena's memory, the original records, and careful human review were all necessary. Lantern simply made the connections easier to explore.

### maya-import-bug-report

Save as: `maya-import-bug-report.wav` · Category: `technical` · 145 words

Create a bug report titled duplicate import after interrupted preview. I tested Lantern version zero point four point two on macOS fourteen point six using the sample folder named Market Photos. The folder contained thirty two JPEG files and one text file called notes dot txt. I selected the folder, opened the preview, and disconnected the external drive before the thumbnails finished loading. The application displayed the message source unavailable, which was expected. After I reconnected the drive and selected retry, every photograph appeared twice in the preview list. I expected the retry operation to continue from the interrupted file and show thirty two photographs. The actual result showed sixty four entries, although nothing was written to the archive database. Closing the preview removed the duplicates. Please preserve the original folder, reproduce with logging disabled, and do not include image contents in the issue attachment.

### maya-search-analysis

Save as: `maya-search-analysis.wav` · Category: `technical` · 146 words

Document the search accuracy review for query set B seven. The set contains fifty queries collected during the volunteer sessions. Forty one queries returned the expected photograph in the first five results. Six returned the correct collection but not the correct photograph, and three returned no useful result. The missed queries included abbreviations, a possessive surname, and the address twelve B North Market Road. Searching for North Market without the building number succeeded. I do not recommend adding automatic fuzzy matching everywhere because short family names produced unrelated results in an earlier test. Instead, we should normalize common street abbreviations, preserve apostrophes in display text, and index a separate comparison form. The acceptance target for the next test is forty seven successful queries out of fifty with no private record appearing in public results. Save this analysis under reports slash search dash B seven dot markdown.

### maya-corrected-schedule

Save as: `maya-corrected-schedule.wav` · Category: `disfluent` · 137 words

Um please update the committee schedule. The review starts at two thirty on Thursday. The review starts at two thirty on Thursday in the reading room, and the remote link opens fifteen minutes earlier. Daniel will demonstrate the import fix first. Daniel will demonstrate the import fix first, then I will show the revised search filters. We should we should reserve twenty minutes for volunteer questions and ten minutes for the recovery exercise. The printed agenda currently says Friday, but Thursday is the correct day. Please keep the room booking for three hours even though the formal session is only ninety minutes. Priya Shah will bring the license register, and I will bring the seven records that still need date confirmation. Send the corrected invitation before noon tomorrow and use the subject Lantern committee review, revised schedule.

### maya-corrected-address

Save as: `maya-corrected-address.wav` · Category: `disfluent` · 137 words

Er create a review note for the parade photograph. The location is Willow Avenue and North Market Road. The location is Willow Avenue and North Market Road, beside the former Bell Pharmacy. I first wrote number fourteen, but the paper directory shows number forty. Keep both statements in the research note and mark forty as the reviewed building number. We should not we should not change Elena's original description, because she identified the pharmacy from memory and did not provide a number. Add the search terms Bell Pharmacy, Willow Avenue, North Market Road, parade, and nineteen sixty three. Link the city directory page but do not attach it until Priya confirms that the scan can be redistributed. The record identifier is photo dash zero zero seven eight, and the review date is Monday the twenty first.

## Daniel

### daniel-first-week-plan

Save as: `daniel-first-week-plan.wav` · Category: `everyday` · 146 words

Here is my plan for the first week of the Lantern pilot. On Monday I will install version zero point four point two on the archive computer and verify that the existing database opens correctly. On Tuesday I will sit with two volunteers while they enter descriptions for ten photographs each. I will take notes about confusing labels, missing keyboard shortcuts, and any search result that appears out of order. Wednesday is reserved for fixes, although I will not change the stored records without making a backup first. On Thursday Maya and I will review the revised workflow together. Friday afternoon is the public demonstration, so the application must be stable by noon. I also want a printed recovery guide beside the computer. If the network is unavailable, volunteers should still be able to save work locally and export a backup to the encrypted archive drive.

### daniel-volunteer-message

Save as: `daniel-volunteer-message.wav` · Category: `everyday` · 152 words

Send a message to the Saturday volunteers. Let them know that the archive room will open at nine fifteen instead of nine because the building manager needs extra time to test the fire alarm. They should bring headphones if they plan to review audio notes, but they do not need to bring a laptop. The two archive computers already have Lantern installed. Remind them to sign in with the temporary volunteer account and never with a personal email address. I will demonstrate the new duplicate warning before we begin. If a warning appears, they should leave both records unchanged and add the yellow review label. At eleven thirty we will stop data entry, save a backup, and discuss anything that felt slow or confusing. Coffee and fruit will be available in the kitchen. Ask anyone with an accessibility request to contact Maya privately before Thursday afternoon so we can prepare the room.

### daniel-recovery-explanation

Save as: `daniel-recovery-explanation.wav` · Category: `long_form` · 170 words

The recovery process has three layers because the archive computer cannot depend on a permanent internet connection. First, Lantern writes each approved change to the local database and verifies that the record can be read back. Second, the application creates an automatic snapshot every thirty minutes while a volunteer session is active. Third, the closing checklist exports an encrypted copy to the archive drive. A snapshot is not a substitute for the closing export because it remains on the same computer. If the internal disk fails, only the archive drive copy can restore that day's work. During the pilot I will inspect the backup summary every morning and perform a test restoration each Wednesday. The test uses a temporary directory and never replaces the working database. After the restored record count and image checksums match, I will delete the temporary copy and sign the paper recovery log. This procedure may sound cautious for a small collection, but the descriptions represent hundreds of volunteer hours that we cannot recreate reliably.

### daniel-post-launch-review

Save as: `daniel-post-launch-review.wav` · Category: `long_form` · 168 words

The pilot ended with more useful feedback than I expected. Volunteers created two hundred and sixteen descriptions, attached forty nine reviewed place names, and flagged eleven possible duplicates. The application remained available throughout both sessions, although one image import took nearly twenty seconds and looked frozen. Nobody lost work, but three people clicked the import button a second time because there was no visible progress message. That is the first issue I want to fix. The second issue concerns keyboard navigation in the review panel. Moving forward through fields works correctly, while moving backward sometimes returns focus to the beginning of the window. I also noticed that our recovery guide explains how to restore the database but not how to reconnect the image directory afterward. None of these problems requires a redesign. I propose a small maintenance release, version zero point four point three, followed by another volunteer test in two weeks. We should publish the known issues before that test so participants know what we are measuring.

### daniel-command-notes

Save as: `daniel-command-notes.wav` · Category: `technical` · 146 words

Add these developer notes to the maintenance ticket. The test database is stored at slash users slash shared slash Lantern slash pilot dot database. Before changing it, run the command sayall doctor and confirm that the configuration status is okay. Then create a backup named pilot dash before dash migration dot database. The migration should update schema version twelve to schema version thirteen without changing the record identifiers. Afterward, run the integrity checker with the read only flag and compare the SHA two fifty six digest against the value in checksums dot txt. The expected record count is two hundred and sixteen. If the count differs, stop immediately and retain both database files. Do not upload either file to the issue tracker because the test descriptions have not been approved for publication. Record only the command exit status, elapsed milliseconds, schema version, and final digest prefix.

### daniel-release-checklist

Save as: `daniel-release-checklist.wav` · Category: `technical` · 145 words

Prepare the release checklist for Lantern zero point four point three. First, confirm that all automated tests pass on Linux and Apple silicon. Second, verify that the package contains the correct helper binary and that the helper reports protocol version three. Third, install the candidate on a clean user account and import the twenty file public sample. Fourth, disconnect the network, edit one description, and confirm that local save and export still work. Fifth, inspect the privacy safe metrics report and make sure it contains counts and timing but no transcript, audio, API key, or provider payload. Finally, compare the release checksum with SHA256SUMS and have Maya approve the candidate identity. Do not publish, sign, or notarize anything from this checklist. Publication requires a separate approval after physical microphone testing and archive committee review. Record every command and result in release dash evidence dot markdown.

### daniel-corrected-version

Save as: `daniel-corrected-version.wav` · Category: `disfluent` · 141 words

Uh add a note to the release ticket. I tested version zero point four point two. I tested version zero point four point two on the archive computer, then repeated the test with the candidate version zero point four point three. The old build took eighteen seconds to import the sample, while the candidate took eleven seconds. We need to we need to verify that the faster result is not caused by cached thumbnails. Delete the temporary preview directory, restart the computer, and run the candidate once more. Save the timing in metrics dash import dot JSON. The expected sample contains twenty files, not twenty two files. If the second candidate run remains below thirteen seconds and the checksum matches, mark the performance issue resolved. Do not close the duplicate import issue because that fix requires a separate interrupted drive test.

### daniel-corrected-backup

Save as: `daniel-corrected-backup.wav` · Category: `disfluent` · 137 words

Erm write the final backup note. The closing export started at five ten. The closing export started at five ten and finished at five twelve without an error. I copied the encrypted file to archive drive A. I copied the encrypted file to archive drive A, then verified its SHA two fifty six digest against the value in the paper log. We should we should retain yesterday's export until the next Wednesday restoration test succeeds. The new file is named Lantern dash pilot dash Friday dot backup and contains two hundred and sixteen records. I almost wrote two hundred and sixty records, but two hundred and sixteen is correct. Maya signed the closing checklist at five twenty. Store the drive in cabinet three, drawer two, and return the cabinet key to the building manager before leaving.

