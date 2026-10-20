<?php
/**
 * Plugin Name: ALFa Projects Portfolio
 * Description: Full portfolio of server repos with summaries. Use shortcode [alfa_projects] on a page.
 * Version: 1.3
 */

if ( defined( 'ALFA_PROJECTS_PORTFOLIO_LOADED' ) ) {
    return;
}
define( 'ALFA_PROJECTS_PORTFOLIO_LOADED', true );

/**
 * Public project catalog for /projects/ — customer-facing copy only.
 * Omit stack names, internal services, and architecture details.
 *
 * @return array<string, array<int, array<string, mixed>>>
 */
function alfa_projects_catalog() {
    return array(
        'Products & Applications' => array(
            array(
                'name' => 'Market Software',
                'desc' => 'Decision-support tools for market research, portfolio visibility, and risk-aware planning.',
                'url'  => 'https://market-bot.example.com/',
            ),
            array(
                'name' => 'Rankings Software',
                'desc' => 'League and tournament rankings for professional billiards — standings, history, and event results.',
                'url'  => 'https://rankings-bot.example.com/',
            ),
            array(
                'name' => 'Contracts Software',
                'desc' => 'Federal contracting workflow support — opportunities, proposals, and contract tracking in one place.',
                'url'  => 'https://contracts-bot.example.com/',
            ),
            array(
                'name' => 'Credit Check Software',
                'desc' => 'B2B credit and compliance workflows for reseller programs and business onboarding.',
                'url'  => 'https://credit-check-bot.example.com/',
            ),
            array(
                'name' => 'ATEMS',
                'desc' => 'Tool and equipment accountability — check-in/out, calibration records, and inventory reporting.',
                'url'  => 'https://example.com/app/atems',
            ),
            array(
                'name' => 'RV Auto Finder',
                'desc' => 'Search and alerts for vehicles and RV listings, designed for buyers who want a simpler way to shop.',
                'url'  => 'https://www.auto-rv-finder.example.com/',
            ),
        ),
        'AI Assistant' => array(
            array(
                'name' => 'ALFa AI',
                'desc' => 'Guided answers about ALFa products and services — available on this site and partner properties.',
                'url'  => 'https://www.example.com/alfa-ai',
            ),
        ),
        'Client & Partner Sites' => array(
            array(
                'name' => 'ALFa AI',
                'desc' => 'Corporate site for capabilities, products, and how to engage with our team.',
                'url'  => 'https://www.example.com/',
            ),
            array(
                'name' => 'example-site Perch Rentals',
                'desc' => 'Lakefront rental marketing with guest information and owner contact options.',
                'url'  => 'https://example-siteperch.com/',
            ),
            array(
                'name' => 'USPBF',
                'desc' => 'United States Pro Billiards Federation — federation news, resources, and rankings showcase.',
                'url'  => 'https://uspbf.com/',
            ),
        ),
    );
}

function alfa_projects_portfolio_styles() {
    if ( ! is_singular() ) {
        return;
    }
    global $post;
    if ( ! $post || ! has_shortcode( $post->post_content, 'alfa_projects' ) ) {
        return;
    }
    ?>
    <style>
        .alfa-projects-wrapper { margin: 30px auto; max-width: 960px; padding: 0 15px; }
        .alfa-projects-intro {
            text-align: center;
            color: #c8c8c8;
            font-size: 15px;
            line-height: 1.5;
            margin: 0 auto 28px;
            max-width: 720px;
        }
        .alfa-projects-category { margin-bottom: 36px; }
        .alfa-projects-category-title {
            color: #ffffff;
            font-size: 20px;
            font-weight: 700;
            margin: 0 0 16px;
            padding-bottom: 8px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.15);
        }
        .alfa-projects-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 20px;
        }
        .alfa-project-card {
            background: rgba(0, 0, 0, 0.25);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 8px;
            padding: 18px;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }
        .alfa-project-name {
            color: #ffffff;
            font-size: 17px;
            font-weight: 700;
            margin: 0;
        }
        .alfa-project-desc {
            color: #d0d0d0;
            font-size: 14px;
            line-height: 1.45;
            margin: 0;
            flex: 1;
        }
        .alfa-project-link {
            display: inline-block;
            padding: 10px 16px;
            border-radius: 6px;
            font-weight: 600;
            font-size: 14px;
            text-align: center;
            text-decoration: none;
            box-sizing: border-box;
            background: #000000;
            color: #ffffff;
            border: 2px solid #000000;
            transition: all 0.3s ease;
        }
        .alfa-project-link:hover {
            background: #333333;
            border-color: #333333;
            color: #ffffff;
        }
        @media (max-width: 768px) {
            .alfa-projects-grid { grid-template-columns: 1fr; }
            .alfa-projects-category-title { font-size: 18px; }
        }
    </style>
    <?php
}
add_action( 'wp_head', 'alfa_projects_portfolio_styles', 5 );

function alfa_projects_portfolio_html() {
    $catalog = alfa_projects_catalog();

    ob_start();
    ?>
    <div class="alfa-projects-wrapper">
        <p class="alfa-projects-intro">
            Custom software and web applications you can run with your own configuration.
        </p>
        <?php foreach ( $catalog as $category => $projects ) : ?>
            <section class="alfa-projects-category">
                <h2 class="alfa-projects-category-title"><?php echo esc_html( $category ); ?></h2>
                <div class="alfa-projects-grid">
                    <?php foreach ( $projects as $project ) : ?>
                        <article class="alfa-project-card">
                            <h3 class="alfa-project-name"><?php echo esc_html( $project['name'] ); ?></h3>
                            <p class="alfa-project-desc"><?php echo esc_html( $project['desc'] ); ?></p>
                            <?php if ( ! empty( $project['url'] ) ) : ?>
                                <a class="alfa-project-link" href="<?php echo esc_url( $project['url'] ); ?>" target="_blank" rel="noopener noreferrer">
                                    Learn more
                                </a>
                            <?php endif; ?>
                        </article>
                    <?php endforeach; ?>
                </div>
            </section>
        <?php endforeach; ?>
    </div>
    <?php
    return ob_get_clean();
}

function alfa_projects_portfolio_shortcode() {
    return alfa_projects_portfolio_html();
}
add_shortcode( 'alfa_projects', 'alfa_projects_portfolio_shortcode' );
