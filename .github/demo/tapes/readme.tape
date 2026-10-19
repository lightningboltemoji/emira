# The README's video: an empty desktop fills with stand-ins, windows of one colour that are only
# there to be moved. Three open along the strip and two stack into a column, and the window beside it
# grows and shrinks. The column's upper window goes fullscreen and back, then leaves the column, and
# focus walks the row. A fourth opens at the end and moves all the way to the front.
Display 1920x1080
Seed 3

# emira's green, and three to go with it.
Color Green 23a862
Color Teal 127d9d
Color Plum 855290
Color Clay dd6d45

Record
Mark desktop
Sleep 1.2s

# A window has the display to itself until the next two open beside it.
Open Green
Wait still
Mark green
Sleep 380ms
Open Teal
Wait still
Sleep 1.1s
Open Plum
Wait still
Mark three
Sleep 1.1s

# Plum stacks under Teal.
Key fn+shift+leftbracket
Wait still
Mark stacked
Sleep 1.1s

# Green, beside the column, grows and shrinks back.
Key fn+h
Wait still
Sleep 600ms
Key fn+equal fn+equal fn+equal
Wait still
Sleep 300ms
Key fn+minus fn+minus fn+minus
Wait still
Mark resized
Sleep 900ms

# Back on the column, at its top: Teal takes the strip, and goes back above Plum.
Key fn+l
Wait still
Sleep 600ms
Key fn+f
Wait still
Mark fullscreen
Sleep 550ms
Key fn+f
Wait still
Sleep 1.1s

# Teal leaves the column, and focus walks the row.
Key fn+shift+rightbracket
Wait still
Mark row
Sleep 1.1s
Key fn+h fn+h
Wait still
Sleep 600ms
Key fn+l fn+l
Wait still
Sleep 250ms

# A fourth opens at the end, and moves all the way to the front.
Open Clay
Wait still
Mark clay
Sleep 1.1s
Key fn+shift+h fn+shift+h fn+shift+h
Wait still
Mark front
Sleep 2.8s
Mark end
