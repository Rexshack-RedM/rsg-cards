-- rsg-cards
-- Only needed when Config.AutoDatabase = false (tables are created automatically otherwise).

-- Upgrading from the old tilp-hdrp-collectablecards? Keep your boxes by running this first:
-- RENAME TABLE `hdrp_boxes` TO `rsg_cards_boxes`;

CREATE TABLE IF NOT EXISTS `rsg_cards_boxes` (
    `serial`  VARCHAR(20) NOT NULL,
    `creator` VARCHAR(50) NOT NULL,
    `owner`   VARCHAR(50) NOT NULL,
    PRIMARY KEY (`serial`),
    INDEX `idx_creator` (`creator`),
    INDEX `idx_owner` (`owner`)
);

CREATE TABLE IF NOT EXISTS `rsg_cards_collection` (
    `citizenid`   VARCHAR(50) NOT NULL,
    `card`        VARCHAR(50) NOT NULL,
    `obtained_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`, `card`)
);

CREATE TABLE IF NOT EXISTS `rsg_cards_pickups` (
    `citizenid` VARCHAR(50) NOT NULL,
    `card`      VARCHAR(50) NOT NULL,
    `picked_at` INT UNSIGNED NOT NULL,
    PRIMARY KEY (`citizenid`, `card`)
);

-- Cards that could not be handed over (e.g. the player left with unopened pack cards). Given on the next login.
CREATE TABLE IF NOT EXISTS `rsg_cards_unclaimed` (
    `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid`  VARCHAR(50) NOT NULL,
    `card`       VARCHAR(50) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_citizenid` (`citizenid`)
);

-- First time a character found every card of a set (set bonus, "first collector" titles).
CREATE TABLE IF NOT EXISTS `rsg_cards_bonuses` (
    `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid`    VARCHAR(50) NOT NULL,
    `set_id`       VARCHAR(20) NOT NULL,
    `completed_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_set` (`citizenid`, `set_id`),
    INDEX `idx_set` (`set_id`)
);

-- Character names shown on the leaderboard.
CREATE TABLE IF NOT EXISTS `rsg_cards_profiles` (
    `citizenid` VARCHAR(50) NOT NULL,
    `name`      VARCHAR(100) NOT NULL,
    PRIMARY KEY (`citizenid`)
);
