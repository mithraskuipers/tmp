on run {input, parameters}
	tell application "Microsoft PowerPoint"
		set theRange to shape range of selection of active window
		set n to count shapes of theRange
		if n < 2 then return input

		set topList to {}
		set botList to {}
		repeat with i from 1 to n
			tell shape i of theRange
				set t to top
				set h to height
			end tell
			set end of topList to t
			set end of botList to (t + h)
		end repeat

		set minTop to item 1 of topList
		set maxBot to item 1 of botList
		repeat with i from 2 to n
			if item i of topList < minTop then set minTop to item i of topList
			if item i of botList > maxBot then set maxBot to item i of botList
		end repeat
		set centerY to (minTop + maxBot) / 2

		repeat with i from 1 to n
			tell shape i of theRange
				set h to height
				set top to centerY - (h / 2)
			end tell
		end repeat
	end tell
	return input
end run
