#!/usr/bin/env bash
# Create About, Blog, and Contact pages with homepage-matching block content.
#
# Usage: sudo bash install-alfa-site-pages.sh

set -euo pipefail

WP_CLI="/home/operator/alfaqd-website/bin/wp-cli.sh"

if [ ! -f "${WP_CLI}" ]; then
  echo "Error: wp-cli not found at ${WP_CLI}"
  exit 1
fi

ensure_page() {
  local slug="$1"
  local title="$2"
  local content="$3"
  local existing
  existing="$(sudo bash "${WP_CLI}" post list --post_type=page --name="${slug}" --field=ID --format=ids 2>/dev/null || true)"
  if [ -n "${existing}" ]; then
    echo "Updating page ${slug} (ID ${existing})..."
    sudo bash "${WP_CLI}" post update "${existing}" --post_title="${title}" --post_status=publish --post_content="${content}"
  else
    echo "Creating page ${slug}..."
    sudo bash "${WP_CLI}" post create --post_type=page --post_title="${title}" --post_name="${slug}" --post_status=publish --post_content="${content}"
  fi
}

ABOUT_CONTENT='<!-- wp:paragraph {"align":"center"} -->
<p class="has-text-align-center"><strong>About Us</strong></p>
<!-- /wp:paragraph -->

<!-- wp:paragraph {"align":"center"} -->
<p class="has-text-align-center"><strong>ALFa AI</strong> is open-source software. You run it with your own configuration.</p>
<!-- /wp:paragraph -->'

CONTACT_CONTENT='<!-- wp:heading {"textAlign":"center","level":5} -->
<h5 class="wp-block-heading has-text-align-center">example N Alfrey Jr.</h5>
<!-- /wp:heading -->

<!-- wp:paragraph {"align":"center"} -->
<p class="has-text-align-center">Questions about this project go to the repository maintainer.</p>
<!-- /wp:paragraph -->

<!-- wp:separator {"className":"is-style-wide"} -->
<hr class="wp-block-separator has-alpha-channel-opacity is-style-wide"/>
<!-- /wp:separator -->

<!-- wp:paragraph {"align":"center"} -->
<p class="has-text-align-center">Ask ALFa AI for my email or FAQ<br>Visit us at the links below</p>
<!-- /wp:paragraph -->

<!-- wp:social-links {"iconBackgroundColor":"black","iconBackgroundColorValue":"#000000","className":"is-content-justification-center"} -->
<ul class="wp-block-social-links has-icon-background-color"><!-- wp:social-link {"url":"https://github.com/Curt-Alfrey-s-Org/public-alfa-ai","service":"github","label":"ALFa AI"} /-->

<!-- wp:social-link {"url":"https://linkedin.com/in/example-alfrey-jr-015a30353","service":"linkedin"} /-->

<!-- wp:social-link {"url":"https://github.com/operator","service":"github"} /-->

<!-- wp:social-link {"url":"https://x.com/example","service":"x","label":"example Alfrey"} /--></ul>
<!-- /wp:social-links -->'

BLOG_CONTENT='<!-- wp:paragraph {"align":"center"} -->
<p class="has-text-align-center">Updates and articles from ALFa AI will appear here. Use the ALFa AI chat for product FAQs in the meantime.</p>
<!-- /wp:paragraph -->'

ensure_page "about" "About" "${ABOUT_CONTENT}"
ensure_page "contact" "Contact" "${CONTACT_CONTENT}"
ensure_page "blog" "Blog" "${BLOG_CONTENT}"

echo "Done. Install site chrome if needed: sudo bash install-alfa-site-chrome.sh"
