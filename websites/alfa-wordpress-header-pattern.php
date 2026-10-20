<?php
/**
 * Title: Header
 * Slug: spectra-one/header
 * Categories: header
 * Block Types: core/template-part/header
 */

$get_url = trailingslashit(get_template_directory_uri());

$images = [
    $get_url . 'assets/image/logo-white.svg',
];

?>
<!-- wp:group {"backgroundColor":"foreground","layout":{"type":"constrained"},"style":{"spacing":{"padding":{"top":"12px","bottom":"12px","left":"24px","right":"24px"}}}} -->
<div class="wp-block-group has-foreground-background-color has-background" style="padding-top:12px;padding-right:24px;padding-bottom:12px;padding-left:24px"><!-- wp:group {"align":"wide","layout":{"type":"flex","flexWrap":"nowrap","justifyContent":"space-between"},"className":"swt-block-row"} -->
<div class="wp-block-group alignwide swt-block-row"><!-- wp:image {"id":849,"sizeSlug":"full","linkDestination":"custom","className":"site-logo-img"} -->
<figure class="wp-block-image size-full site-logo-img"><a href="<?php echo esc_url( get_home_url() ); ?>">
<img src="<?php echo esc_url( $images[0] ); ?>" alt="ALFa AI" class="wp-image-849" />
</a></figure>
<!-- /wp:image -->
<!-- wp:group {"style":{"spacing":{"blockGap":"var:preset|spacing|large"}},"layout":{"type":"flex","flexWrap":"nowrap","justifyContent":"right"},"className":"swt-block-row"} -->
<div class="wp-block-group swt-block-row"><!-- wp:navigation {"textColor":"white","overlayTextColor":"black","layout":{"type":"flex","justifyContent":"right"},"style":{"spacing":{"blockGap":"var:preset|spacing|medium"}}} -->
<!-- wp:navigation-link {"label":"Home","url":"<?php echo esc_url( get_home_url() ); ?>","kind":"custom","isTopLevelLink":true} /-->
<!-- wp:navigation-link {"label":"About","url":"<?php echo esc_url( get_home_url( null, '/about/' ) ); ?>","kind":"custom","isTopLevelLink":true} /-->
<!-- wp:navigation-link {"label":"Projects","url":"<?php echo esc_url( get_home_url( null, '/projects/' ) ); ?>","kind":"custom","isTopLevelLink":true} /-->
<!-- wp:navigation-link {"label":"Blog","url":"<?php echo esc_url( get_home_url( null, '/blog/' ) ); ?>","kind":"custom","isTopLevelLink":true} /-->
<!-- wp:navigation-link {"label":"Contact","url":"<?php echo esc_url( get_home_url( null, '/contact/' ) ); ?>","kind":"custom","isTopLevelLink":true} /-->
<!-- /wp:navigation -->
<!-- wp:buttons {"SWTHideMob":true} -->
<div class="wp-block-buttons"><!-- wp:button {"style":{"border":{"radius":"6px"}},"className":"is-style-swt-button-inverse"} -->
<div class="wp-block-button is-style-swt-button-inverse"><a class="wp-block-button__link wp-element-button" href="<?php echo esc_url( get_home_url( null, '/contact/' ) ); ?>" style="border-radius:6px">Get Started</a></div>
<!-- /wp:button --></div>
<!-- /wp:buttons --></div>
<!-- /wp:group --></div>
<!-- /wp:group --></div>
<!-- /wp:group -->
