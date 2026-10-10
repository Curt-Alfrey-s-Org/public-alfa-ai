# WordPress guest chat corpus (not used at runtime)

The public widget on each WordPress site answers only from **that site's
published pages and posts**. The plugin builds the primer with WordPress
`get_pages()` / `get_posts()` (`post_status=publish`). See
`docs/ALFA_AI_CHAT_WIDGETS.md` (knowledge scope).

Do not put a cluster-wide product list here. To change what the homepage
chat can say, edit the public pages on that WordPress site, then wait for
the 15-minute corpus cache (or save any post to clear it).
