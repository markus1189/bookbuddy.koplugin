local _ = require("gettext")
return {
    fullname = _("BookBuddy"),
    description = _(
        [[Chat with Claude about a highlighted passage. Claude can search the book, read passages, and use the table of contents to answer your questions.]]
    ),
    version = "1.12.1",
}
