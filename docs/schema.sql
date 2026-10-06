-- =============================================================================
-- Apparel WMS (RFID 服装零售 WMS) · 数据库建表脚本
-- 目标：MySQL 5.7.x  InnoDB / utf8mb4 / ROW_FORMAT=DYNAMIC
-- 生成：2026-10-06 v1.0   配套文档：docs/项目需求.md、docs/数据库ER.md、docs/接口设计.md
--
-- 【MySQL 5.7 适配约定】
--   1. 不使用 CHECK 约束（5.7 解析但不生效）→ 取值范围校验全部在应用层 Service 完成。
--   2. 不使用物理外键（便于导入/分区/分库），关系靠 *_id + 索引维护，一致性由事务保证。
--   3. 状态字段用 varchar(24/32) + 注释枚举值，可读性优先于 tinyint 映射；索引宽度可控。
--   4. 长字符串建索引一律 ≤ varchar(191)，utf8mb4 下不触 767 字节限制。
--   5. 所有表：id bigint unsigned auto_increment 主键；created_at / updated_at；
--      主数据表带 is_deleted 软删（0 正常 1 已删），单据表用 status='cancelled' 代替。
--   6. 数量用 int(件)，金额用 decimal(12,2)，禁止 float。
--   7. rfid_read_log 为高写入表：不做唯一约束（同 EPC 允许重复读取，业务去重在消费端 +
--      unique(task_id,epc) 这类约束放在结果表上），按 read_time 建索引，建议 90 天后归档。
--   8. 若后续启用多租户（FR-SYS-08），为业务表增加 tenant_id bigint unsigned default 0
--      并将所有 unique key 改为 (tenant_id, ...) 前缀 —— 需整体重排唯一索引，列为独立迁移。
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE IF NOT EXISTS `fashion_wms`
  DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_general_ci;
USE `fashion_wms`;


-- =============================================================================
-- 01 系统域 sys_*
-- =============================================================================

DROP TABLE IF EXISTS `sys_user`;
CREATE TABLE `sys_user` (
  `id`            bigint unsigned NOT NULL AUTO_INCREMENT,
  `username`      varchar(64)  NOT NULL COMMENT '登录账号',
  `password`      varchar(255) NOT NULL COMMENT 'bcrypt 哈希',
  `real_name`     varchar(64)  NOT NULL DEFAULT '' COMMENT '姓名',
  `phone`         varchar(20)  NOT NULL DEFAULT '',
  `email`         varchar(128) NOT NULL DEFAULT '',
  `avatar`        varchar(255) NOT NULL DEFAULT '',
  `user_type`     varchar(16)  NOT NULL DEFAULT 'wh' COMMENT 'admin总部/wh仓库/store门店/pda手持',
  `warehouse_id`  bigint unsigned NOT NULL DEFAULT 0 COMMENT '默认仓库（数据范围用）',
  `store_id`      bigint unsigned NOT NULL DEFAULT 0 COMMENT '默认门店',
  `status`        varchar(16)  NOT NULL DEFAULT 'active' COMMENT 'active/disabled/locked',
  `last_login_at` datetime     DEFAULT NULL,
  `last_login_ip` varchar(45)  NOT NULL DEFAULT '',
  `remark`        varchar(255) NOT NULL DEFAULT '',
  `is_deleted`    tinyint      NOT NULL DEFAULT 0,
  `created_at`    datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`    datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_username` (`username`),
  KEY `idx_wh` (`warehouse_id`), KEY `idx_store` (`store_id`), KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='用户';

DROP TABLE IF EXISTS `sys_role`;
CREATE TABLE `sys_role` (
  `id`          bigint unsigned NOT NULL AUTO_INCREMENT,
  `code`        varchar(64)  NOT NULL COMMENT '角色编码 admin/wh_manager/receiver/checker/store_manager/clk',
  `name`        varchar(64)  NOT NULL,
  `data_scope`  varchar(16)  NOT NULL DEFAULT 'warehouse' COMMENT 'all全部/warehouse本仓/store本店/self本人',
  `remark`      varchar(255) NOT NULL DEFAULT '',
  `status`      varchar(16)  NOT NULL DEFAULT 'active',
  `created_at`  datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='角色';

DROP TABLE IF EXISTS `sys_user_role`;
CREATE TABLE `sys_user_role` (
  `id`        bigint unsigned NOT NULL AUTO_INCREMENT,
  `user_id`   bigint unsigned NOT NULL,
  `role_id`   bigint unsigned NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_user_role` (`user_id`,`role_id`), KEY `idx_role` (`role_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='用户角色';

DROP TABLE IF EXISTS `sys_permission`;
CREATE TABLE `sys_permission` (
  `id`        bigint unsigned NOT NULL AUTO_INCREMENT,
  `parent_id` bigint unsigned NOT NULL DEFAULT 0,
  `name`      varchar(64) NOT NULL COMMENT '名称',
  `code`      varchar(128) NOT NULL COMMENT '权限码 如 master:spu:create / inbound:asn:audit',
  `type`      varchar(16) NOT NULL DEFAULT 'menu' COMMENT 'menu菜单/button按钮/api接口',
  `path`      varchar(191) NOT NULL DEFAULT '' COMMENT '前端路由或接口路径',
  `icon`      varchar(64)  NOT NULL DEFAULT '',
  `level`     smallint     NOT NULL DEFAULT 1,
  `sort`      int          NOT NULL DEFAULT 0,
  `status`    varchar(16)  NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`), KEY `idx_parent` (`parent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='权限（菜单/按钮/接口）';

DROP TABLE IF EXISTS `sys_role_permission`;
CREATE TABLE `sys_role_permission` (
  `id`            bigint unsigned NOT NULL AUTO_INCREMENT,
  `role_id`       bigint unsigned NOT NULL,
  `permission_id` bigint unsigned NOT NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_role_perm` (`role_id`,`permission_id`), KEY `idx_perm` (`permission_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='角色权限';

DROP TABLE IF EXISTS `sys_dict_type`;
CREATE TABLE `sys_dict_type` (
  `id`        bigint unsigned NOT NULL AUTO_INCREMENT,
  `type_code` varchar(64) NOT NULL COMMENT '字典类型 season季节/wave波段/category/stock_state/inventory_state等',
  `name`      varchar(64) NOT NULL,
  `status`    varchar(16) NOT NULL DEFAULT 'active',
  `remark`    varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_type_code` (`type_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='字典类型';

DROP TABLE IF EXISTS `sys_dict_item`;
CREATE TABLE `sys_dict_item` (
  `id`        bigint unsigned NOT NULL AUTO_INCREMENT,
  `type_code` varchar(64)  NOT NULL,
  `item_code` varchar(64)  NOT NULL COMMENT '字典值',
  `item_label` varchar(64) NOT NULL COMMENT '显示名',
  `ext_value` varchar(191) NOT NULL DEFAULT '' COMMENT '扩展值（颜色HEX、EPC前缀等）',
  `sort`      int          NOT NULL DEFAULT 0,
  `status`    varchar(16)  NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_type_item` (`type_code`,`item_code`), KEY `idx_type` (`type_code`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='字典项';

DROP TABLE IF EXISTS `sys_config`;
CREATE TABLE `sys_config` (
  `id`           bigint unsigned NOT NULL AUTO_INCREMENT,
  `group_code`   varchar(32)  NOT NULL DEFAULT 'default' COMMENT 'rfid/inventory/system',
  `config_key`   varchar(128) NOT NULL COMMENT '如 rfid.dedup_window_s / rfid.heartbeat_offline_s',
  `config_value` text COMMENT '值',
  `value_type`   varchar(16)  NOT NULL DEFAULT 'string' COMMENT 'string/int/float/bool/json',
  `name`         varchar(64)  NOT NULL DEFAULT '',
  `remark`       varchar(255) NOT NULL DEFAULT '',
  `updated_at`   datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_config_key` (`config_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='系统参数（热生效）';

DROP TABLE IF EXISTS `sys_serial_rule`;
CREATE TABLE `sys_serial_rule` (
  `id`         bigint unsigned NOT NULL AUTO_INCREMENT,
  `biz_type`   varchar(32) NOT NULL COMMENT 'ASN/RECEIPT/WAVE/CHECK/SHIPMENT/TRANSFER/RETURN/COUNT/ADJUST/PRINT/MOVEMENT/DISCREPANCY/PUTAWAY/REPLENISH/BOX',
  `prefix`     varchar(16) NOT NULL COMMENT '单号前缀',
  `date_format` varchar(16) NOT NULL DEFAULT 'Ymd' COMMENT 'Ymd/Ym/none',
  `seq_length` tinyint NOT NULL DEFAULT 3,
  `sample`     varchar(64) NOT NULL DEFAULT '' COMMENT '示例 ASN-20261003-01',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_biz_type` (`biz_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='单号规则';

DROP TABLE IF EXISTS `sys_serial_seq`;
CREATE TABLE `sys_serial_seq` (
  `id`         bigint unsigned NOT NULL AUTO_INCREMENT,
  `rule_id`    bigint unsigned NOT NULL,
  `date_key`   varchar(16)  NOT NULL COMMENT '按日/月分段的键',
  `current_seq` int unsigned NOT NULL DEFAULT 0,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_rule_date` (`rule_id`,`date_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='单号流水（SELECT .. FOR UPDATE 取号）';

DROP TABLE IF EXISTS `sys_idempotency`;
CREATE TABLE `sys_idempotency` (
  `id`             bigint unsigned NOT NULL AUTO_INCREMENT,
  `idempotency_key` varchar(128) NOT NULL COMMENT '客户端 request_id 或 device_code+batch_no',
  `api`            varchar(191) NOT NULL DEFAULT '',
  `scope_type`     varchar(16)  NOT NULL DEFAULT 'user' COMMENT 'user/device',
  `scope_id`       bigint unsigned NOT NULL DEFAULT 0,
  `result_code`    int          NOT NULL DEFAULT 0,
  `result_body`    text COMMENT '首次响应快照（幂等重放用）',
  `expire_at`      datetime     DEFAULT NULL,
  `created_at`     datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_key` (`idempotency_key`), KEY `idx_expire` (`expire_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='幂等键（设备上报与写接口防重）';

DROP TABLE IF EXISTS `sys_operation_log`;
CREATE TABLE `sys_operation_log` (
  `id`        bigint unsigned NOT NULL AUTO_INCREMENT,
  `user_id`   bigint unsigned NOT NULL DEFAULT 0,
  `username`  varchar(64) NOT NULL DEFAULT '',
  `module`    varchar(32) NOT NULL DEFAULT '' COMMENT '模块 in_bound/out_bound/inventory...',
  `action`    varchar(32) NOT NULL DEFAULT '' COMMENT 'create/audit/cancel/unbind/adjust',
  `biz_type`  varchar(32) NOT NULL DEFAULT '',
  `biz_id`    bigint unsigned NOT NULL DEFAULT 0,
  `method`    varchar(10)  NOT NULL DEFAULT '',
  `url`       varchar(191) NOT NULL DEFAULT '',
  `params`    text COMMENT '脱敏后的请求参数',
  `before_data` text COMMENT '关键单据变更前值（库存/EPC/审核）',
  `after_data`  text COMMENT '变更后值',
  `ip`        varchar(45)  NOT NULL DEFAULT '',
  `trace_id`  varchar(32)  NOT NULL DEFAULT '' COMMENT '与响应体 trace_id / 结构化日志同值，排障线索',
  `result`    varchar(16)  NOT NULL DEFAULT 'success' COMMENT 'success/fail',
  `error_msg` varchar(500) NOT NULL DEFAULT '',
  `duration_ms` int unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_user_time` (`user_id`,`created_at`), KEY `idx_biz` (`biz_type`,`biz_id`),
  KEY `idx_module_action` (`module`,`action`,`created_at`), KEY `idx_trace` (`trace_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='操作日志';

DROP TABLE IF EXISTS `sys_login_log`;
CREATE TABLE `sys_login_log` (
  `id`       bigint unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL DEFAULT '',
  `user_id`  bigint unsigned NOT NULL DEFAULT 0,
  `ip`       varchar(45)  NOT NULL DEFAULT '',
  `ua`       varchar(255) NOT NULL DEFAULT '',
  `terminal` varchar(16)  NOT NULL DEFAULT 'web' COMMENT 'web/pda/device',
  `result`   varchar(16)  NOT NULL DEFAULT 'success' COMMENT 'success/fail',
  `fail_reason` varchar(128) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_user_time` (`username`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='登录日志';

DROP TABLE IF EXISTS `sys_import_batch`;
CREATE TABLE `sys_import_batch` (
  `id`         bigint unsigned NOT NULL AUTO_INCREMENT,
  `biz_type`   varchar(32) NOT NULL COMMENT 'product/sku/stock/epc',
  `file_name`  varchar(191) NOT NULL DEFAULT '',
  `total_rows` int NOT NULL DEFAULT 0,
  `ok_rows`    int NOT NULL DEFAULT 0,
  `fail_rows`  int NOT NULL DEFAULT 0,
  `error_file_path` varchar(255) NOT NULL DEFAULT '' COMMENT '逐行错误报告',
  `status`     varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/parsing/success/partial/failed',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_type_time` (`biz_type`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='Excel 导入批次';


-- =============================================================================
-- 02 主数据域 md_*
-- =============================================================================

DROP TABLE IF EXISTS `md_brand`;
CREATE TABLE `md_brand` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL, `name` varchar(64) NOT NULL,
  `logo` varchar(255) NOT NULL DEFAULT '', `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='品牌';

DROP TABLE IF EXISTS `md_category`;
CREATE TABLE `md_category` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `parent_id` bigint unsigned NOT NULL DEFAULT 0,
  `code` varchar(64) NOT NULL, `name` varchar(64) NOT NULL,
  `level` smallint NOT NULL DEFAULT 1, `sort` int NOT NULL DEFAULT 0,
  `path` varchar(255) NOT NULL DEFAULT '' COMMENT '父子路径，便于树查询',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`), KEY `idx_parent` (`parent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='品类（外套/毛衣/…）';

DROP TABLE IF EXISTS `md_color`;
CREATE TABLE `md_color` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `color_code` varchar(16) NOT NULL COMMENT '色码 BK/KH/NV/WH',
  `color_name` varchar(32) NOT NULL COMMENT '黑色/卡其…',
  `hex_value`  varchar(16) NOT NULL DEFAULT '' COMMENT '矩阵展示用色块',
  `pantone`    varchar(32) NOT NULL DEFAULT '',
  `sort` int NOT NULL DEFAULT 0, `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_color_code` (`color_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='颜色字典（矩阵行）';

DROP TABLE IF EXISTS `md_size`;
CREATE TABLE `md_size` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `size_code` varchar(16) NOT NULL COMMENT '尺码 XS/S/M/L/XL/XXL 或 26/27/28',
  `size_name` varchar(32) NOT NULL,
  `size_group` varchar(16) NOT NULL DEFAULT 'adult' COMMENT 'adult成人/kid童装/freef均码',
  `sort` int NOT NULL DEFAULT 0, `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_size_code` (`size_code`,`size_group`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='尺码字典（矩阵列）';

DROP TABLE IF EXISTS `md_supplier`;
CREATE TABLE `md_supplier` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL, `name` varchar(128) NOT NULL,
  `contact` varchar(64) NOT NULL DEFAULT '', `phone` varchar(20) NOT NULL DEFAULT '',
  `address` varchar(255) NOT NULL DEFAULT '',
  `tolerance_qty` int NOT NULL DEFAULT 0 COMMENT '入库允许差异件数（业务规则1，默认0零容差）',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='供应商（东莞制衣厂/杭州丝绸…）';

DROP TABLE IF EXISTS `md_carrier`;
CREATE TABLE `md_carrier` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL COMMENT 'SF/JD/…', `name` varchar(64) NOT NULL COMMENT '顺丰速运/京东物流',
  `api_type` varchar(24) NOT NULL DEFAULT 'none' COMMENT '对接方式 none/http/sdk',
  `config` text COMMENT '承运商对接参数(json)',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='物流承运商';

DROP TABLE IF EXISTS `md_warehouse`;
CREATE TABLE `md_warehouse` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL, `name` varchar(128) NOT NULL COMMENT '总仓/华东仓',
  `type` varchar(16) NOT NULL DEFAULT 'center' COMMENT 'center总仓/sort分仓/virtual虚拟仓',
  `contact` varchar(64) NOT NULL DEFAULT '', `phone` varchar(20) NOT NULL DEFAULT '',
  `region` varchar(32) NOT NULL DEFAULT '' COMMENT '上海区/北京区（波次聚合用）',
  `address` varchar(255) NOT NULL DEFAULT '',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='仓库';

DROP TABLE IF EXISTS `md_store`;
CREATE TABLE `md_store` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL COMMENT '门店编码 SH-01/BJ-01（与分拣墙格口目标一致）',
  `name` varchar(128) NOT NULL COMMENT '上海南京路旗舰店',
  `warehouse_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '归属补货仓',
  `region` varchar(32) NOT NULL DEFAULT '',
  `contact` varchar(64) NOT NULL DEFAULT '', `phone` varchar(20) NOT NULL DEFAULT '',
  `address` varchar(255) NOT NULL DEFAULT '',
  `open_at` date DEFAULT NULL, `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`), KEY `idx_region` (`region`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='门店';

DROP TABLE IF EXISTS `md_area`;
CREATE TABLE `md_area` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `warehouse_id` bigint unsigned NOT NULL,
  `code` varchar(32) NOT NULL COMMENT 'A/B/R（A区秋季新品、退货暂存区）',
  `name` varchar(64) NOT NULL,
  `type` varchar(16) NOT NULL DEFAULT 'storage' COMMENT 'storage存储/picking拣货/return退货暂存/defect次品/staging待发',
  `turnover` varchar(16) NOT NULL DEFAULT 'normal' COMMENT '周转等级 fast/normal/slow（上架建议用）',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wh_code` (`warehouse_id`,`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='库区';

DROP TABLE IF EXISTS `md_location`;
CREATE TABLE `md_location` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `warehouse_id` bigint unsigned NOT NULL,
  `area_id` bigint unsigned NOT NULL,
  `code` varchar(64) NOT NULL COMMENT '库位编码 A-01-03',
  `name` varchar(64) NOT NULL DEFAULT '',
  `type` varchar(16) NOT NULL DEFAULT 'shelf' COMMENT 'shelf货架/floor地堆/pallet托盘位/stage暂存',
  `capacity` int NOT NULL DEFAULT 0 COMMENT '容量（件）',
  `used_qty` int NOT NULL DEFAULT 0 COMMENT '已用（由 inv_stock 汇总回填）',
  `sort_path` varchar(32) NOT NULL DEFAULT '' COMMENT '拣货路径顺序',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wh_code` (`warehouse_id`,`code`), KEY `idx_area` (`area_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='库位';

DROP TABLE IF EXISTS `md_product`;
CREATE TABLE `md_product` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `spu_code` varchar(64) NOT NULL COMMENT '款号 AW26-JK-01',
  `name` varchar(128) NOT NULL COMMENT '品名 秋季轻奢风衣',
  `brand_id` bigint unsigned NOT NULL DEFAULT 0,
  `category_id` bigint unsigned NOT NULL DEFAULT 0,
  `season` varchar(16) NOT NULL DEFAULT '' COMMENT '季节 2026秋',
  `wave` varchar(16) NOT NULL DEFAULT '' COMMENT '波段 波1/波2',
  `gender` varchar(16) NOT NULL DEFAULT 'unisex' COMMENT 'male/female/unisex/kid',
  `year` smallint NOT NULL DEFAULT 0,
  `tag_price` decimal(12,2) NOT NULL DEFAULT 0.00 COMMENT '吊牌价',
  `cost_price` decimal(12,2) NOT NULL DEFAULT 0.00 COMMENT '成本价',
  `unit` varchar(16) NOT NULL DEFAULT '件',
  `pack_qty` int NOT NULL DEFAULT 0 COMMENT '每箱标准装量（差异分析用）',
  `image_url` varchar(255) NOT NULL DEFAULT '',
  `epc_rule_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '默认 EPC 规则',
  `status` varchar(16) NOT NULL DEFAULT 'active' COMMENT 'active在售/discontinued已下市',
  `remark` varchar(255) NOT NULL DEFAULT '',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_spu_code` (`spu_code`),
  KEY `idx_season_wave` (`season`,`wave`), KEY `idx_category` (`category_id`), KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='商品 SPU（款号）';

DROP TABLE IF EXISTS `md_sku`;
CREATE TABLE `md_sku` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `sku_code` varchar(64) NOT NULL COMMENT 'SKU 编码 AW26-JK-01-BK-L（款号-色-码）',
  `product_id` bigint unsigned NOT NULL,
  `color_id` bigint unsigned NOT NULL,
  `size_id` bigint unsigned NOT NULL,
  `barcode` varchar(64) NOT NULL DEFAULT '' COMMENT 'UPC/EAN-13',
  `spec_label` varchar(64) NOT NULL DEFAULT '' COMMENT '展示用「黑色 / L」',
  `tag_price` decimal(12,2) NOT NULL DEFAULT 0.00,
  `cost_price` decimal(12,2) NOT NULL DEFAULT 0.00,
  `weight_g` int NOT NULL DEFAULT 0,
  `is_on_sale` tinyint NOT NULL DEFAULT 1 COMMENT '是否在售（缺码预警只看在售）',
  `epc_rule_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '为空则取 SPU 规则',
  `status` varchar(16) NOT NULL DEFAULT 'active' COMMENT 'active/disabled（disabled 禁止发码）',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_sku_code` (`sku_code`),
  KEY `idx_product` (`product_id`), KEY `idx_barcode` (`barcode`),
  KEY `idx_color_size` (`color_id`,`size_id`), KEY `idx_sale_status` (`is_on_sale`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='商品 SKU（色码矩阵单元格）';


-- =============================================================================
-- 03 RFID 域 rfid_*
-- =============================================================================

DROP TABLE IF EXISTS `rfid_epc_rule`;
CREATE TABLE `rfid_epc_rule` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `rule_code` varchar(64) NOT NULL COMMENT '规则编码',
  `name` varchar(64) NOT NULL COMMENT 'UPC + 序列号 / EAN-13 + 序列号 / 自定义96bit',
  `rule_type` varchar(24) NOT NULL DEFAULT 'upc_sn' COMMENT 'upc_sn/ean13_sn/custom_96',
  `epc_length` tinyint NOT NULL DEFAULT 24 COMMENT 'EPC 十六进制字符长度（96bit=24）',
  `header_hex` varchar(8) NOT NULL DEFAULT '3004' COMMENT '96bit Header',
  `tmf` varchar(8) NOT NULL DEFAULT '' COMMENT 'TMF 一般 000000000000000000000000000 (28bit)',
  `company_prefix` varchar(32) NOT NULL DEFAULT '' COMMENT '公司码/GS1 前缀',
  `mask_hex` varchar(32) NOT NULL DEFAULT '' COMMENT '写入掩码（MemoryBank AccessPassword 相关）',
  `serial_min` bigint unsigned NOT NULL DEFAULT 1,
  `serial_max` bigint unsigned NOT NULL DEFAULT 0 COMMENT '0 表示不限',
  `serial_current` bigint unsigned NOT NULL DEFAULT 0 COMMENT '当前已发序列号',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_rule_code` (`rule_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='EPC 编码规则（FR-MD-04）';

DROP TABLE IF EXISTS `rfid_tag_template`;
CREATE TABLE `rfid_tag_template` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `code` varchar(64) NOT NULL, `name` varchar(64) NOT NULL,
  `lang` varchar(16) NOT NULL DEFAULT 'ZPL' COMMENT 'ZPL/TSPL/CPCL',
  `width_mm` decimal(6,2) NOT NULL DEFAULT 60.00, `height_mm` decimal(6,2) NOT NULL DEFAULT 30.00,
  `content` text NOT NULL COMMENT '模板正文，含变量占位 {EPC} {SKU_CODE} {PRICE}',
  `variables` varchar(255) NOT NULL DEFAULT '' COMMENT '逗号分隔变量清单',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='标签打印模板（FR-MD-08）';

DROP TABLE IF EXISTS `rfid_print_job`;
CREATE TABLE `rfid_print_job` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `job_no` varchar(32) NOT NULL COMMENT '打印任务号',
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '0=按 SPU 多 SKU 分摊',
  `epc_rule_id` bigint unsigned NOT NULL,
  `template_id` bigint unsigned NOT NULL DEFAULT 0,
  `device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT 'RFID 打印机',
  `planned_qty` int NOT NULL DEFAULT 0 COMMENT '计划张数',
  `printed_qty` int NOT NULL DEFAULT 0,
  `failed_qty` int NOT NULL DEFAULT 0,
  `batch_no` varchar(32) NOT NULL DEFAULT '' COMMENT '发码批次',
  `status` varchar(16) NOT NULL DEFAULT 'queued' COMMENT 'queued/printing/done/failed/cancelled/part_failed',
  `error_msg` varchar(500) NOT NULL DEFAULT '',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_job_no` (`job_no`),
  KEY `idx_sku` (`sku_id`), KEY `idx_status` (`status`,`created_at`), KEY `idx_device` (`device_id`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='发码打印任务（FR-MD-05）';

DROP TABLE IF EXISTS `rfid_tag`;
CREATE TABLE `rfid_tag` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `epc` varchar(32) NOT NULL COMMENT '96bit EPC 十六进制字符串，全局唯一',
  `tid` varchar(32) NOT NULL DEFAULT '' COMMENT '标签 TID（防伪校验，可空）',
  `user_data` varchar(64) NOT NULL DEFAULT '',
  `product_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL,
  `barcode` varchar(64) NOT NULL DEFAULT '' COMMENT '发码时快照 UPC/EAN',
  `serial_no` bigint unsigned NOT NULL DEFAULT 0 COMMENT '规则内序列号（便于反查）',
  `print_job_id` bigint unsigned NOT NULL DEFAULT 0,
  `batch_no` varchar(32) NOT NULL DEFAULT '' COMMENT '发码批次',
  `produce_date` date DEFAULT NULL COMMENT '生产/绑定日期（库龄起算）',
  `status` varchar(24) NOT NULL DEFAULT 'bound' COMMENT '待写入pending_write/已绑定bound/在库in_stock/已上架put_away/波次锁定wave_locked/出库中checking/在途in_transit/门店在库store_stock/已销售sold/已退货returned/已解绑unbound/报废scrapped/盘亏遗失lost',
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse' COMMENT 'warehouse/store',
  `owner_id` bigint unsigned NOT NULL DEFAULT 0,
  `area_code` varchar(32) NOT NULL DEFAULT '' COMMENT '盘点/拣货用区域 A/B/R',
  `location_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '0=未上架（收货区）',
  `stock_type` varchar(16) NOT NULL DEFAULT 'normal' COMMENT 'normal良品/defect次品/frozen冻结/quarantine待检',
  `bind_device_code` varchar(64) NOT NULL DEFAULT '',
  `bind_time` datetime DEFAULT NULL,
  `in_stock_time` datetime DEFAULT NULL COMMENT '收货入仓时间',
  `out_time` datetime DEFAULT NULL COMMENT '出库时间',
  `sold_time` datetime DEFAULT NULL,
  `unbind_time` datetime DEFAULT NULL,
  `wave_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '当前锁定波次',
  `order_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '当前锁定订单',
  `version` int NOT NULL DEFAULT 0 COMMENT '乐观锁（EPC 归属并发转移）',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_epc` (`epc`),
  KEY `idx_sku_status` (`sku_id`,`status`),
  KEY `idx_product` (`product_id`),
  KEY `idx_owner` (`owner_type`,`owner_id`,`status`),
  KEY `idx_location` (`location_id`,`status`),
  KEY `idx_batch` (`batch_no`),
  KEY `idx_wave` (`wave_id`),
  KEY `idx_print_job` (`print_job_id`),
  KEY `idx_barcode` (`barcode`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='EPC 单品档案（单品级追踪主表，1.24M 量级）';

DROP TABLE IF EXISTS `rfid_tag_event`;
CREATE TABLE `rfid_tag_event` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `epc` varchar(32) NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `event_type` varchar(24) NOT NULL COMMENT 'bind绑定/receive收货/putaway上架/move移库/wave_lock锁定/pick拣货/sort分拣/check复核/ship发货/arrive到店/sale销售/return退货/unbind解绑/rebind重绑/scrap报废/lost盘亏/gain盘盈/freeze冻结/unfreeze解冻',
  `from_owner_type` varchar(16) NOT NULL DEFAULT '', `from_owner_id` bigint unsigned NOT NULL DEFAULT 0,
  `from_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `to_owner_type` varchar(16) NOT NULL DEFAULT '', `to_owner_id` bigint unsigned NOT NULL DEFAULT 0,
  `to_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `from_status` varchar(24) NOT NULL DEFAULT '', `to_status` varchar(24) NOT NULL DEFAULT '',
  `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `read_batch_id` bigint unsigned NOT NULL DEFAULT 0,
  `biz_type` varchar(24) NOT NULL DEFAULT '', `biz_id` bigint unsigned NOT NULL DEFAULT 0,
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_epc_time` (`epc`,`created_at`),
  KEY `idx_biz` (`biz_type`,`biz_id`), KEY `idx_sku_time` (`sku_id`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='EPC 生命周期事件（RF-02/RF-03 审计链）';

DROP TABLE IF EXISTS `rfid_read_batch`;
CREATE TABLE `rfid_read_batch` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `batch_no` varchar(64) NOT NULL COMMENT '设备侧批次号（device_code+ts+seq），幂等键',
  `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `device_code` varchar(64) NOT NULL,
  `scene` varchar(24) NOT NULL COMMENT 'gate通道门/desktop桌面/pda手持/sortwall分拣墙/fitting试衣间/printer打印',
  `biz_type` varchar(24) NOT NULL DEFAULT '' COMMENT 'asn/receipt/stocktake/sort/check/store_receive/find/scrap',
  `biz_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '关联单据（收货单/盘点任务/波次…）',
  `raw_count` int NOT NULL DEFAULT 0 COMMENT '上报标签条数',
  `distinct_count` int NOT NULL DEFAULT 0 COMMENT '去重后件数',
  `dup_count` int NOT NULL DEFAULT 0 COMMENT '窗口内重复',
  `stray_count` int NOT NULL DEFAULT 0 COMMENT '非本单据 EPC（串读）',
  `unknown_count` int NOT NULL DEFAULT 0 COMMENT '系统无档 EPC',
  `duration_ms` int unsigned NOT NULL DEFAULT 0 COMMENT '本次读取耗时',
  `process_status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/processing/done/failed/rejected',
  `process_msg` varchar(500) NOT NULL DEFAULT '',
  `started_at` datetime(3) DEFAULT NULL, `finished_at` datetime(3) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_batch_no` (`batch_no`),
  KEY `idx_biz` (`biz_type`,`biz_id`), KEY `idx_device_time` (`device_id`,`created_at`),
  KEY `idx_process` (`process_status`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='读取批次（一次过门/一次挥扫）';

DROP TABLE IF EXISTS `rfid_read_log`;
CREATE TABLE `rfid_read_log` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `batch_id` bigint unsigned NOT NULL,
  `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `epc` varchar(32) NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '解析后回填（0=无档）',
  `rssi` smallint NOT NULL DEFAULT 0 COMMENT 'dBm（信号强度，找货/串读过滤用）',
  `antenna_no` tinyint NOT NULL DEFAULT 0 COMMENT '天线号',
  `phase` decimal(6,2) DEFAULT NULL COMMENT '相位（定位辅助，可空）',
  `read_count` int NOT NULL DEFAULT 1 COMMENT '窗口内读到次数',
  `is_first` tinyint NOT NULL DEFAULT 1 COMMENT '1=窗口内首次（参与计件）',
  `is_stray` tinyint NOT NULL DEFAULT 0 COMMENT '1=不属于当前单据（串读）',
  `read_time` datetime(3) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_batch` (`batch_id`), KEY `idx_epc_time` (`epc`,`read_time`),
  KEY `idx_device_time` (`device_id`,`read_time`), KEY `idx_sku_time` (`sku_id`,`read_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='原始读取日志（高写入表，保留≥90天，按月归档）';


-- =============================================================================
-- 04 设备域 dev_*
-- =============================================================================

DROP TABLE IF EXISTS `dev_device`;
CREATE TABLE `dev_device` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `device_code` varchar(64) NOT NULL COMMENT '设备编码 GATE-A01 / PDA-05 / PRINT-01',
  `name` varchar(128) NOT NULL COMMENT '1号月台 RFID 通道门',
  `device_type` varchar(24) NOT NULL COMMENT 'gate通道门/desktop桌面机/printer打印机/pda手持/sortwall分拣墙/fitting试衣间',
  `model` varchar(64) NOT NULL DEFAULT '' COMMENT '型号/厂商',
  `driver` varchar(32) NOT NULL DEFAULT 'sim' COMMENT '接入驱动 sim/厂商编码（适配层）',
  `mac` varchar(32) NOT NULL DEFAULT '', `ip` varchar(45) NOT NULL DEFAULT '', `port` int NOT NULL DEFAULT 0,
  `api_config` text COMMENT '厂商 SDK/HTTP 参数(json)',
  `warehouse_id` bigint unsigned NOT NULL DEFAULT 0,
  `store_id` bigint unsigned NOT NULL DEFAULT 0,
  `area_id` bigint unsigned NOT NULL DEFAULT 0,
  `location_text` varchar(128) NOT NULL DEFAULT '' COMMENT '位置展示「总仓 1号月台」',
  `owner_user_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '负责人（盘点组 A）',
  `auth_token` varchar(128) NOT NULL DEFAULT '' COMMENT '设备上报鉴权 token（哈希存储）',
  `heartbeat_limit_s` int NOT NULL DEFAULT 120 COMMENT '无心跳判离线阈值（秒）',
  `dedup_window_s` int NOT NULL DEFAULT 3 COMMENT '同 EPC 去重窗口（秒）',
  `rssi_min` smallint NOT NULL DEFAULT 0 COMMENT 'RSSI 过滤门限（串读抑制）',
  `online_status` varchar(16) NOT NULL DEFAULT 'offline' COMMENT 'online在线/offline离线/charging充电中/no_paper缺纸/fault故障/disabled停用',
  `last_heartbeat_at` datetime DEFAULT NULL,
  `status` varchar(16) NOT NULL DEFAULT 'active' COMMENT 'active启用/disabled停用',
  `firmware` varchar(32) NOT NULL DEFAULT '',
  `remark` varchar(255) NOT NULL DEFAULT '',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_device_code` (`device_code`),
  KEY `idx_type_status` (`device_type`,`status`), KEY `idx_online` (`online_status`,`last_heartbeat_at`),
  KEY `idx_wh` (`warehouse_id`), KEY `idx_store` (`store_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='RFID/IoT 设备台账';

DROP TABLE IF EXISTS `dev_heartbeat`;
CREATE TABLE `dev_heartbeat` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `device_id` bigint unsigned NOT NULL,
  `device_code` varchar(64) NOT NULL,
  `online` tinyint NOT NULL DEFAULT 1,
  `battery` tinyint NOT NULL DEFAULT -1 COMMENT '电量 %，-1 不适用',
  `signal` tinyint NOT NULL DEFAULT -1 COMMENT '信号格 0-5',
  `paper_left` tinyint NOT NULL DEFAULT -1 COMMENT '打印机余纸 %',
  `temperature` decimal(5,1) DEFAULT NULL,
  `read_count_today` int NOT NULL DEFAULT 0 COMMENT '心跳携带当日累计',
  `extra` varchar(500) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_dev_time` (`device_id`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='设备心跳流水（保留30天）';

DROP TABLE IF EXISTS `dev_alarm`;
CREATE TABLE `dev_alarm` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `device_id` bigint unsigned NOT NULL, `device_code` varchar(64) NOT NULL,
  `alarm_type` varchar(24) NOT NULL COMMENT 'no_paper缺纸/offline离线/read_fail读取失败率超阈/high_miss漏读超标/over_read串读/temp高温/fault故障',
  `level` tinyint NOT NULL DEFAULT 2 COMMENT '1提示2警告3严重',
  `message` varchar(500) NOT NULL DEFAULT '',
  `value_text` varchar(128) NOT NULL DEFAULT '' COMMENT '触发值（如 漏读率 0.8%）',
  `status` varchar(16) NOT NULL DEFAULT 'open' COMMENT 'open/acking/acked/closed/ignored',
  `ack_user_id` bigint unsigned NOT NULL DEFAULT 0, `ack_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_dev_status` (`device_id`,`status`), KEY `idx_time` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='设备告警（FR-DV-04）';

DROP TABLE IF EXISTS `dev_read_stat`;
CREATE TABLE `dev_read_stat` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `device_id` bigint unsigned NOT NULL, `device_code` varchar(64) NOT NULL,
  `stat_date` date NOT NULL,
  `scene` varchar(24) NOT NULL DEFAULT 'all',
  `batch_count` int NOT NULL DEFAULT 0 COMMENT '批次数',
  `raw_count` int NOT NULL DEFAULT 0 COMMENT '原始读取条数',
  `epc_count` int NOT NULL DEFAULT 0 COMMENT '今日读取件数（看板用）',
  `dup_count` int NOT NULL DEFAULT 0, `stray_count` int NOT NULL DEFAULT 0, `unknown_count` int NOT NULL DEFAULT 0,
  `avg_duration_ms` int NOT NULL DEFAULT 0, `max_batch_count` int NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_dev_date_scene` (`device_id`,`stat_date`,`scene`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='设备读取日统计';

DROP TABLE IF EXISTS `dev_command`;
CREATE TABLE `dev_command` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `device_id` bigint unsigned NOT NULL, `device_code` varchar(64) NOT NULL,
  `cmd_type` varchar(24) NOT NULL COMMENT 'light_on亮灯/light_off/reset_wall重置/assign_cell分配格口/dispatch_count下发盘点/print_tag打印/start_read开始读取/stop_read停止',
  `payload` text COMMENT '指令参数(json)',
  `biz_type` varchar(24) NOT NULL DEFAULT '', `biz_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/sent/acked/failed/timeout',
  `sent_at` datetime DEFAULT NULL, `acked_at` datetime DEFAULT NULL, `retry_times` tinyint NOT NULL DEFAULT 0,
  `result_msg` varchar(500) NOT NULL DEFAULT '',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_dev_status` (`device_id`,`status`,`created_at`), KEY `idx_biz` (`biz_type`,`biz_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='设备指令下发（灯光/盘点任务/打印）';


-- =============================================================================
-- 05 入库域 in_*
-- =============================================================================

DROP TABLE IF EXISTS `in_asn`;
CREATE TABLE `in_asn` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `asn_no` varchar(32) NOT NULL COMMENT 'ASN-20261003-01',
  `asn_type` varchar(16) NOT NULL DEFAULT 'purchase' COMMENT 'purchase采购/return顾客退货/transfer调拨入/adjust盘盈',
  `supplier_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '东莞制衣厂',
  `warehouse_id` bigint unsigned NOT NULL,
  `source_doc_no` varchar(64) NOT NULL DEFAULT '' COMMENT '来源单号（ERP 采购单）',
  `expected_at` datetime DEFAULT NULL COMMENT '预约到货时间',
  `gate_device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '指定通道门',
  `sku_kind` int NOT NULL DEFAULT 0 COMMENT '款数（SKU 数）',
  `expected_qty` int NOT NULL DEFAULT 0 COMMENT '预期件数',
  `read_qty` int NOT NULL DEFAULT 0 COMMENT '通道门实读',
  `received_qty` int NOT NULL DEFAULT 0 COMMENT '确认收货件数',
  `diff_qty` int NOT NULL DEFAULT 0 COMMENT '差异（可为负）',
  `status` varchar(24) NOT NULL DEFAULT 'appointed' COMMENT 'appointed预约中/waiting_gate等待过门/receiving收货中/diff_pending差异待处理/completed已完成/cancelled已取消/closed已关闭',
  `creator_id` bigint unsigned NOT NULL DEFAULT 0,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_asn_no` (`asn_no`),
  KEY `idx_status` (`status`,`expected_at`), KEY `idx_supplier` (`supplier_id`), KEY `idx_wh` (`warehouse_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='ASN 入库通知单（FR-IN-01）';

DROP TABLE IF EXISTS `in_asn_item`;
CREATE TABLE `in_asn_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `asn_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL,
  `expected_qty` int NOT NULL DEFAULT 0,
  `read_qty` int NOT NULL DEFAULT 0 COMMENT '实读（按 EPC 归集）',
  `received_qty` int NOT NULL DEFAULT 0 COMMENT '确认收货',
  `diff_qty` int NOT NULL DEFAULT 0,
  `stray_qty` int NOT NULL DEFAULT 0 COMMENT '异常件（不属于本 ASN）',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_asn_sku` (`asn_id`,`sku_id`), KEY `idx_sku` (`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='ASN 明细';

DROP TABLE IF EXISTS `in_receipt`;
CREATE TABLE `in_receipt` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `receipt_no` varchar(32) NOT NULL,
  `biz_type` varchar(16) NOT NULL DEFAULT 'asn' COMMENT 'asn/transfer/return/count_gain/blind盲收',
  `biz_id` bigint unsigned NOT NULL DEFAULT 0,
  `biz_no` varchar(32) NOT NULL DEFAULT '',
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse' COMMENT 'warehouse总仓/store门店（门店收货复用本表）',
  `owner_id` bigint unsigned NOT NULL,
  `area_code` varchar(32) NOT NULL DEFAULT '' COMMENT '收货区',
  `device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '通道门/PDA',
  `expected_qty` int NOT NULL DEFAULT 0,
  `read_qty` int NOT NULL DEFAULT 0 COMMENT '已读取',
  `confirmed_qty` int NOT NULL DEFAULT 0 COMMENT '已确认入库',
  `diff_qty` int NOT NULL DEFAULT 0,
  `state` varchar(24) NOT NULL DEFAULT 'scanning' COMMENT 'scanning过门中/diff差异待处理/confirmed已确认/completed已完成/cancelled取消',
  `blind_flag` tinyint NOT NULL DEFAULT 0 COMMENT '盲收（无 ASN，需权限+备注）',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `started_at` datetime DEFAULT NULL, `finished_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_receipt_no` (`receipt_no`),
  KEY `idx_biz` (`biz_type`,`biz_id`), KEY `idx_owner_state` (`owner_type`,`owner_id`,`state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='收货单（含门店 PDA 收货）';

DROP TABLE IF EXISTS `in_receipt_item`;
CREATE TABLE `in_receipt_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `receipt_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `epc` varchar(32) NOT NULL DEFAULT '',
  `qty` int NOT NULL DEFAULT 1 COMMENT '按 EPC 记录时=1',
  `is_stray` tinyint NOT NULL DEFAULT 0 COMMENT '异常件',
  `is_confirmed` tinyint NOT NULL DEFAULT 0,
  `handle_type` varchar(16) NOT NULL DEFAULT '' COMMENT 'rescan补扫/partial部分收货/hold挂起/reassign归属调整',
  `batch_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_receipt` (`receipt_id`,`is_confirmed`), KEY `idx_epc` (`epc`), KEY `idx_sku` (`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='收货明细（EPC/SKU 双粒度）';

DROP TABLE IF EXISTS `in_discrepancy`;
CREATE TABLE `in_discrepancy` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `disc_no` varchar(32) NOT NULL,
  `biz_type` varchar(24) NOT NULL COMMENT 'receipt收货/store_receive门店收货/sort_wall分拣/check复核',
  `biz_id` bigint unsigned NOT NULL, `biz_no` varchar(32) NOT NULL DEFAULT '',
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse', `owner_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0, `epc` varchar(32) NOT NULL DEFAULT '',
  `diff_type` varchar(16) NOT NULL COMMENT 'short少件/over多件/stray串读夹带/damaged污损/unknown无档码',
  `expected_qty` int NOT NULL DEFAULT 0, `actual_qty` int NOT NULL DEFAULT 0, `diff_qty` int NOT NULL DEFAULT 0,
  `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending待处理/processing处理中/resolved已处理/adjusting转调整/ignored忽略',
  `handler_id` bigint unsigned NOT NULL DEFAULT 0, `handled_at` datetime DEFAULT NULL,
  `handle_result` varchar(500) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_disc_no` (`disc_no`),
  KEY `idx_biz` (`biz_type`,`biz_id`), KEY `idx_status` (`status`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='作业差异单（少件/多件/串读/污损）';

DROP TABLE IF EXISTS `in_putaway_task`;
CREATE TABLE `in_putaway_task` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_no` varchar(32) NOT NULL,
  `receipt_id` bigint unsigned NOT NULL DEFAULT 0,
  `warehouse_id` bigint unsigned NOT NULL,
  `plan_qty` int NOT NULL DEFAULT 0, `done_qty` int NOT NULL DEFAULT 0,
  `suggest_area` varchar(32) NOT NULL DEFAULT '' COMMENT '上架建议区域',
  `assignee_id` bigint unsigned NOT NULL DEFAULT 0, `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/doing/done/cancelled',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_task_no` (`task_no`), KEY `idx_receipt` (`receipt_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='上架任务（FR-IN-06）';

DROP TABLE IF EXISTS `in_putaway_item`;
CREATE TABLE `in_putaway_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0, `epc` varchar(32) NOT NULL DEFAULT '',
  `suggest_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `actual_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `qty` int NOT NULL DEFAULT 1, `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/done',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_task` (`task_id`,`status`), KEY `idx_epc` (`epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='上架明细';


-- =============================================================================
-- 06 库存域 inv_*
-- =============================================================================

DROP TABLE IF EXISTS `inv_stock`;
CREATE TABLE `inv_stock` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse' COMMENT 'warehouse/store',
  `owner_id` bigint unsigned NOT NULL,
  `location_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '0=未分库位（收货区）；门店用陈列/后仓虚拟位',
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL,
  `stock_type` varchar(16) NOT NULL DEFAULT 'normal' COMMENT 'normal良品/frozen冻结/defect次品/quarantine待检/transit在途',
  `qty` int NOT NULL DEFAULT 0 COMMENT '账面数量（件，>=0 应用层保证）',
  `locked_qty` int NOT NULL DEFAULT 0 COMMENT '波次/订单锁定',
  `epc_qty` int NOT NULL DEFAULT 0 COMMENT '在档 EPC 数（对账：应等于 qty）',
  `first_in_time` datetime DEFAULT NULL COMMENT '最早入库时间（库龄）',
  `version` int NOT NULL DEFAULT 0 COMMENT '乐观锁',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_stock_dim` (`owner_type`,`owner_id`,`location_id`,`sku_id`,`stock_type`),
  KEY `idx_sku` (`sku_id`), KEY `idx_owner` (`owner_type`,`owner_id`,`stock_type`),
  KEY `idx_product` (`product_id`), KEY `idx_location` (`location_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='库存数量台账（可售=qty-locked_qty）';

DROP TABLE IF EXISTS `inv_transaction`;
CREATE TABLE `inv_transaction` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `txn_no` varchar(40) NOT NULL COMMENT '流水号',
  `owner_type` varchar(16) NOT NULL, `owner_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL, `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `epc` varchar(32) NOT NULL DEFAULT '',
  `from_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `to_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `stock_type` varchar(16) NOT NULL DEFAULT 'normal',
  `change_qty` int NOT NULL COMMENT '带符号变动量',
  `qty_before` int NOT NULL DEFAULT 0, `qty_after` int NOT NULL DEFAULT 0,
  `direction` varchar(8) NOT NULL DEFAULT 'in' COMMENT 'in/out/adjust',
  `biz_type` varchar(24) NOT NULL COMMENT 'receipt/putaway/move/count_gain/count_loss/wave_lock/unlock/pick/check/ship/transfer_out/transfer_in/sale/return/unbind/scrap/init期初',
  `biz_id` bigint unsigned NOT NULL DEFAULT 0, `biz_no` varchar(32) NOT NULL DEFAULT '',
  `device_id` bigint unsigned NOT NULL DEFAULT 0, `batch_id` bigint unsigned NOT NULL DEFAULT 0,
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `amount` decimal(12,2) NOT NULL DEFAULT 0.00 COMMENT '成本金额（盘盈亏/销售成本）',
  `dedup_key` varchar(128) DEFAULT NULL COMMENT '幂等键：{biz_type}:{biz_id}:{sku_id|epc}:{direction}:{stock_type}；重复提交时 INSERT IGNORE 拦截。非幂等流水写 NULL（NULL 不参与唯一约束）',
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_dedup` (`dedup_key`),
  KEY `idx_sku_time` (`sku_id`,`created_at`), KEY `idx_owner_time` (`owner_type`,`owner_id`,`created_at`),
  KEY `idx_biz` (`biz_type`,`biz_id`), KEY `idx_epc` (`epc`), KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='库存流水（不可物理删除，支撑回放与对账；uk_dedup 保证同一单据同一 SKU/EPC 只计一次）';

DROP TABLE IF EXISTS `inv_movement`;
CREATE TABLE `inv_movement` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `move_no` varchar(32) NOT NULL,
  `warehouse_id` bigint unsigned NOT NULL,
  `from_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `to_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `reason` varchar(24) NOT NULL DEFAULT 'normal_move' COMMENT 'normal_move常规/optimize补位/quality质检/replenish后仓到卖场',
  `plan_qty` int NOT NULL DEFAULT 0, `done_qty` int NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/doing/done/cancelled',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0, `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_move_no` (`move_no`), KEY `idx_wh_status` (`warehouse_id`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='移库单';

DROP TABLE IF EXISTS `inv_movement_item`;
CREATE TABLE `inv_movement_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `move_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0, `epc` varchar(32) NOT NULL DEFAULT '',
  `qty` int NOT NULL DEFAULT 1,
  `from_location_id` bigint unsigned NOT NULL DEFAULT 0, `to_location_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_move` (`move_id`,`status`), KEY `idx_epc` (`epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='移库明细';

DROP TABLE IF EXISTS `inv_safety_stock`;
CREATE TABLE `inv_safety_stock` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `owner_type` varchar(16) NOT NULL, `owner_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '按款设置（服装主流）',
  `sku_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '0=按款；>0 精确到色码',
  `size_code` varchar(16) NOT NULL DEFAULT '' COMMENT '配合 product_id 做"按尺码"的缺码判定',
  `min_qty` int NOT NULL DEFAULT 0 COMMENT '最低（低于即缺码预警）',
  `max_qty` int NOT NULL DEFAULT 0,
  `replenish_qty` int NOT NULL DEFAULT 0 COMMENT '建议补货量',
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_owner_dim` (`owner_type`,`owner_id`,`product_id`,`sku_id`,`size_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='安全库存/补货点';

-- 盘点：任务 / 实盘记录 / 差异 / 盈亏调整

DROP TABLE IF EXISTS `cnt_task`;
CREATE TABLE `cnt_task` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_no` varchar(32) NOT NULL COMMENT 'INV-A-1003',
  `task_type` varchar(16) NOT NULL DEFAULT 'area' COMMENT 'area库区/store门店/spot抽查/full全盘/daily打烊日盘',
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse', `owner_id` bigint unsigned NOT NULL,
  `area_code` varchar(32) NOT NULL DEFAULT '' COMMENT 'A/B/R（A区秋季新品、退货暂存区）',
  `scope_desc` varchar(255) NOT NULL DEFAULT '' COMMENT '范围描述',
  `blind_flag` tinyint NOT NULL DEFAULT 1 COMMENT '盲盘（不显示账面）FR-IV-04',
  `plan_sku_count` int NOT NULL DEFAULT 0 COMMENT '应盘 SKU 数',
  `book_qty` int NOT NULL DEFAULT 0 COMMENT '账面件数',
  `counted_sku_count` int NOT NULL DEFAULT 0,
  `actual_qty` int NOT NULL DEFAULT 0 COMMENT '实盘件数',
  `diff_qty` int NOT NULL DEFAULT 0,
  `accuracy` decimal(6,4) NOT NULL DEFAULT 0.0000 COMMENT '准确率 = 命中SKU / 应盘SKU',
  `progress` tinyint NOT NULL DEFAULT 0 COMMENT '进度 0-100',
  `device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '执行 PDA / 盘点车',
  `assignee_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending待执行/counting盘点中/done已完成/audited已审核/recount复盘中/cancelled取消',
  `started_at` datetime DEFAULT NULL, `finished_at` datetime DEFAULT NULL,
  `audit_user_id` bigint unsigned NOT NULL DEFAULT 0, `audit_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_task_no` (`task_no`),
  KEY `idx_owner_status` (`owner_type`,`owner_id`,`status`), KEY `idx_device` (`device_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='盘点任务';

DROP TABLE IF EXISTS `cnt_record`;
CREATE TABLE `cnt_record` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_id` bigint unsigned NOT NULL,
  `epc` varchar(32) NOT NULL,
  `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `location_id` bigint unsigned NOT NULL DEFAULT 0,
  `area_code` varchar(32) NOT NULL DEFAULT '',
  `rssi` smallint NOT NULL DEFAULT 0,
  `batch_id` bigint unsigned NOT NULL DEFAULT 0,
  `round_no` tinyint NOT NULL DEFAULT 1 COMMENT '第几轮（复盘=2）',
  `is_unexpected` tinyint NOT NULL DEFAULT 0 COMMENT '1=账外（盘盈来源）',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_task_epc_round` (`task_id`,`epc`,`round_no`),
  KEY `idx_task_sku` (`task_id`,`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='盘点实盘记录（EPC 去重在此表唯一键保证）';

DROP TABLE IF EXISTS `cnt_diff`;
CREATE TABLE `cnt_diff` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `location_id` bigint unsigned NOT NULL DEFAULT 0,
  `book_qty` int NOT NULL DEFAULT 0, `actual_qty` int NOT NULL DEFAULT 0,
  `diff_qty` int NOT NULL DEFAULT 0 COMMENT '实盘-账面',
  `diff_type` varchar(12) NOT NULL DEFAULT '' COMMENT 'gain盈/loss亏/misplaced错位',
  `cause` varchar(32) NOT NULL DEFAULT '' COMMENT '未归因/unattended未盘/lost遗失/stolen被盗/ship_short少发/return未入账/other',
  `review_status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending待审/recount需复盘/confirmed已确认/rejected驳回',
  `reviewer_id` bigint unsigned NOT NULL DEFAULT 0, `reviewed_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_task_sku_loc` (`task_id`,`sku_id`,`location_id`),
  KEY `idx_task_status` (`task_id`,`review_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='盘点差异表';

DROP TABLE IF EXISTS `cnt_adjust`;
CREATE TABLE `cnt_adjust` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `adjust_no` varchar(32) NOT NULL,
  `task_id` bigint unsigned NOT NULL DEFAULT 0,
  `owner_type` varchar(16) NOT NULL, `owner_id` bigint unsigned NOT NULL,
  `gain_qty` int NOT NULL DEFAULT 0, `loss_qty` int NOT NULL DEFAULT 0,
  `amount` decimal(12,2) NOT NULL DEFAULT 0.00 COMMENT '调整成本金额',
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending待审/approved已审/posted已过账/cancelled',
  `creator_id` bigint unsigned NOT NULL DEFAULT 0,
  `approver_id` bigint unsigned NOT NULL DEFAULT 0, `approved_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_adjust_no` (`adjust_no`), KEY `idx_task` (`task_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='盘盈亏调整单';

DROP TABLE IF EXISTS `cnt_adjust_item`;
CREATE TABLE `cnt_adjust_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `adjust_id` bigint unsigned NOT NULL,
  `sku_id` bigint unsigned NOT NULL, `epc` varchar(32) NOT NULL DEFAULT '',
  `stock_type` varchar(16) NOT NULL DEFAULT 'normal',
  `diff_qty` int NOT NULL DEFAULT 0,
  `cost_price` decimal(12,2) NOT NULL DEFAULT 0.00,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_adjust` (`adjust_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='调整明细';


-- =============================================================================
-- 07 出库域 out_*
-- =============================================================================

DROP TABLE IF EXISTS `out_order`;
CREATE TABLE `out_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `order_no` varchar(32) NOT NULL,
  `order_type` varchar(16) NOT NULL DEFAULT 'store_transfer' COMMENT 'store_transfer门店调拨/ec电商订单/shop门店直发/return_supplier退供/transfer_out仓库调拨',
  `owner_type` varchar(16) NOT NULL DEFAULT 'warehouse', `owner_id` bigint unsigned NOT NULL COMMENT '发货仓',
  `target_type` varchar(16) NOT NULL DEFAULT 'store' COMMENT 'store/store_order/customer/supplier/warehouse',
  `target_id` bigint unsigned NOT NULL DEFAULT 0,
  `target_code` varchar(64) NOT NULL DEFAULT '' COMMENT 'SH-01（分拣墙格口匹配用）',
  `target_name` varchar(128) NOT NULL DEFAULT '',
  `source_no` varchar(64) NOT NULL DEFAULT '' COMMENT '外部单号（OMS/ERP）',
  `carrier_id` bigint unsigned NOT NULL DEFAULT 0,
  `plan_qty` int NOT NULL DEFAULT 0, `picked_qty` int NOT NULL DEFAULT 0,
  `sorted_qty` int NOT NULL DEFAULT 0, `checked_qty` int NOT NULL DEFAULT 0, `shipped_qty` int NOT NULL DEFAULT 0,
  `priority` tinyint NOT NULL DEFAULT 2 COMMENT '1加急2普通3低',
  `eta` datetime DEFAULT NULL COMMENT '预计送达（TR-8821 预计明日10:00）',
  `status` varchar(24) NOT NULL DEFAULT 'pending' COMMENT 'pending待分配/waved已入波次/picking拣货中/sorting分拣中/checking复核中/ready待发运/shipped已发货/received已签收/cancelled取消',
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_order_no` (`order_no`),
  KEY `idx_status` (`status`,`priority`), KEY `idx_target` (`target_type`,`target_id`),
  KEY `idx_owner` (`owner_type`,`owner_id`), KEY `idx_source` (`source_no`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='出库单（需求单）';

DROP TABLE IF EXISTS `out_order_item`;
CREATE TABLE `out_order_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `order_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL,
  `plan_qty` int NOT NULL DEFAULT 0,
  `locked_qty` int NOT NULL DEFAULT 0, `picked_qty` int NOT NULL DEFAULT 0,
  `sorted_qty` int NOT NULL DEFAULT 0, `shipped_qty` int NOT NULL DEFAULT 0,
  `short_qty` int NOT NULL DEFAULT 0 COMMENT '缺货数',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_order_sku` (`order_id`,`sku_id`), KEY `idx_sku` (`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='出库单明细';

DROP TABLE IF EXISTS `out_wave`;
CREATE TABLE `out_wave` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `wave_no` varchar(32) NOT NULL COMMENT 'WAVE-1003-A',
  `warehouse_id` bigint unsigned NOT NULL,
  `target_desc` varchar(128) NOT NULL DEFAULT '' COMMENT '上海区 5 家门店',
  `region` varchar(32) NOT NULL DEFAULT '',
  `order_count` int NOT NULL DEFAULT 0,
  `plan_qty` int NOT NULL DEFAULT 0, `picked_qty` int NOT NULL DEFAULT 0,
  `sorted_qty` int NOT NULL DEFAULT 0, `checked_qty` int NOT NULL DEFAULT 0, `shipped_qty` int NOT NULL DEFAULT 0,
  `carrier_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '顺丰速运/京东物流',
  `wall_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '分拣墙',
  `status` varchar(24) NOT NULL DEFAULT 'planned' COMMENT 'planned已计划/picking拣货中/sorting分拣中/checking复核中/loaded已装车/shipped已发货/cancelled取消',
  `creator_id` bigint unsigned NOT NULL DEFAULT 0,
  `loaded_at` datetime DEFAULT NULL, `shipped_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wave_no` (`wave_no`),
  KEY `idx_status` (`status`,`created_at`), KEY `idx_wh` (`warehouse_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='波次（FR-OB-01）';

DROP TABLE IF EXISTS `out_wave_order`;
CREATE TABLE `out_wave_order` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `wave_id` bigint unsigned NOT NULL, `order_id` bigint unsigned NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wave_order` (`wave_id`,`order_id`), KEY `idx_order` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='波次-出库单关系';

DROP TABLE IF EXISTS `out_pick_task`;
CREATE TABLE `out_pick_task` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `pick_no` varchar(32) NOT NULL,
  `wave_id` bigint unsigned NOT NULL,
  `warehouse_id` bigint unsigned NOT NULL,
  `plan_qty` int NOT NULL DEFAULT 0, `picked_qty` int NOT NULL DEFAULT 0,
  `assignee_id` bigint unsigned NOT NULL DEFAULT 0, `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `route` text COMMENT '库位拣货路径（按 sort_path 生成）',
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/doing/paused/done/cancelled',
  `started_at` datetime DEFAULT NULL, `finished_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_pick_no` (`pick_no`), KEY `idx_wave` (`wave_id`), KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='拣货任务';

DROP TABLE IF EXISTS `out_pick_item`;
CREATE TABLE `out_pick_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `pick_id` bigint unsigned NOT NULL, `wave_id` bigint unsigned NOT NULL,
  `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `location_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL, `epc` varchar(32) NOT NULL DEFAULT '',
  `plan_qty` int NOT NULL DEFAULT 1, `picked_qty` int NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/done/short缺货',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_pick_status` (`pick_id`,`status`), KEY `idx_epc` (`epc`), KEY `idx_wave_sku` (`wave_id`,`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='拣货明细';

DROP TABLE IF EXISTS `out_sort_wall`;
CREATE TABLE `out_sort_wall` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `wall_code` varchar(32) NOT NULL COMMENT 'WALL-01',
  `name` varchar(64) NOT NULL COMMENT 'RFID 智能分拣墙',
  `warehouse_id` bigint unsigned NOT NULL,
  `device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '格口控制板设备',
  `scan_device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '扫描读写器',
  `cell_count` smallint NOT NULL DEFAULT 12,
  `columns` tinyint NOT NULL DEFAULT 6 COMMENT '展示列数（原型 6 列）',
  `current_wave_id` bigint unsigned NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'idle' COMMENT 'idle空闲/working作业中/fault故障',
  `is_deleted` tinyint NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wall_code` (`wall_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='分拣墙（播种墙）';

DROP TABLE IF EXISTS `out_sort_cell`;
CREATE TABLE `out_sort_cell` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `wall_id` bigint unsigned NOT NULL,
  `cell_no` smallint NOT NULL COMMENT '格口号 01-12',
  `cell_code` varchar(16) NOT NULL DEFAULT '' COMMENT '展示用 01',
  `target_type` varchar(16) NOT NULL DEFAULT '' COMMENT 'store/order，未分配为空',
  `target_id` bigint unsigned NOT NULL DEFAULT 0,
  `target_code` varchar(64) NOT NULL DEFAULT '' COMMENT 'SH-01',
  `target_name` varchar(128) NOT NULL DEFAULT '',
  `wave_id` bigint unsigned NOT NULL DEFAULT 0,
  `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `assigned_qty` int NOT NULL DEFAULT 0 COMMENT '应投件数',
  `sorted_qty` int NOT NULL DEFAULT 0 COMMENT '已投件数',
  `error_qty` int NOT NULL DEFAULT 0 COMMENT '错投次数',
  `light_state` varchar(12) NOT NULL DEFAULT 'off' COMMENT 'off/lighted闪烁/error红',
  `status` varchar(16) NOT NULL DEFAULT 'idle' COMMENT 'idle空闲/active命中/error错分/full满载/done完成',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_wall_cell` (`wall_id`,`cell_no`),
  KEY `idx_wave` (`wave_id`), KEY `idx_target` (`target_type`,`target_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='分拣墙格口';

DROP TABLE IF EXISTS `out_sort_record`;
CREATE TABLE `out_sort_record` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `wall_id` bigint unsigned NOT NULL, `cell_id` bigint unsigned NOT NULL DEFAULT 0,
  `wave_id` bigint unsigned NOT NULL DEFAULT 0, `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `epc` varchar(32) NOT NULL, `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `expect_cell_no` smallint NOT NULL DEFAULT 0 COMMENT '应投格口',
  `actual_cell_no` smallint NOT NULL DEFAULT 0 COMMENT '实投格口（灯光确认/人工选择）',
  `result` varchar(12) NOT NULL DEFAULT 'ok' COMMENT 'ok成功/wrong错分/unknown非本波次/dup重复投',
  `device_id` bigint unsigned NOT NULL DEFAULT 0, `batch_id` bigint unsigned NOT NULL DEFAULT 0,
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `message` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_wave_cell` (`wave_id`,`cell_id`), KEY `idx_epc` (`epc`), KEY `idx_result` (`result`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='分拣扫描记录（防错审计）';

DROP TABLE IF EXISTS `out_check`;
CREATE TABLE `out_check`(
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `check_no` varchar(32) NOT NULL,
  `wave_id` bigint unsigned NOT NULL DEFAULT 0, `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `warehouse_id` bigint unsigned NOT NULL,
  `device_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '复核通道门/桌面机',
  `plan_qty` int NOT NULL DEFAULT 0, `read_qty` int NOT NULL DEFAULT 0, `diff_qty` int NOT NULL DEFAULT 0,
  `state` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/checking/passed通过/blocked拦截（差异未处理不许装车）/done完成',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `started_at` datetime DEFAULT NULL, `finished_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_check_no` (`check_no`), KEY `idx_wave_state` (`wave_id`,`state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='出库复核单（FR-OB-05）';

DROP TABLE IF EXISTS `out_check_item`;
CREATE TABLE `out_check_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `check_id` bigint unsigned NOT NULL,
  `epc` varchar(32) NOT NULL, `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `result` varchar(12) NOT NULL DEFAULT 'ok' COMMENT 'ok/extra多装/missing应装未读',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_check_epc` (`check_id`,`epc`), KEY `idx_result` (`result`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='复核明细';

DROP TABLE IF EXISTS `out_shipment`;
CREATE TABLE `out_shipment` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `ship_no` varchar(32) NOT NULL,
  `wave_id` bigint unsigned NOT NULL DEFAULT 0,
  `warehouse_id` bigint unsigned NOT NULL,
  `target_type` varchar(16) NOT NULL DEFAULT 'store', `target_id` bigint unsigned NOT NULL DEFAULT 0,
  `carrier_id` bigint unsigned NOT NULL DEFAULT 0, `waybill_no` varchar(64) NOT NULL DEFAULT '',
  `box_count` int NOT NULL DEFAULT 0, `piece_qty` int NOT NULL DEFAULT 0,
  `weight_kg` decimal(10,3) NOT NULL DEFAULT 0.000,
  `driver` varchar(64) NOT NULL DEFAULT '', `driver_phone` varchar(20) NOT NULL DEFAULT '',
  `plate_no` varchar(16) NOT NULL DEFAULT '' COMMENT '车牌',
  `status` varchar(24) NOT NULL DEFAULT 'loading' COMMENT 'loading装车中/departed已发运/in_transit在途/arrived已到店/received已签收/exception异常',
  `departed_at` datetime DEFAULT NULL, `arrived_at` datetime DEFAULT NULL, `received_at` datetime DEFAULT NULL,
  `creator_id` bigint unsigned NOT NULL DEFAULT 0,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_ship_no` (`ship_no`),
  KEY `idx_wave` (`wave_id`), KEY `idx_status` (`status`,`created_at`), KEY `idx_waybill` (`waybill_no`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='发货单';

DROP TABLE IF EXISTS `out_box`;
CREATE TABLE `out_box` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `shipment_id` bigint unsigned NOT NULL,
  `box_no` varchar(32) NOT NULL COMMENT '箱号（箱码）',
  `cell_no` smallint NOT NULL DEFAULT 0 COMMENT '来源格口',
  `order_id` bigint unsigned NOT NULL DEFAULT 0,
  `piece_qty` int NOT NULL DEFAULT 0, `weight_kg` decimal(10,3) NOT NULL DEFAULT 0.000,
  `status` varchar(16) NOT NULL DEFAULT 'packed' COMMENT 'packed已装箱/loaded已装车/received已收',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_ship_box` (`shipment_id`,`box_no`), KEY `idx_order` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='箱（一单多箱）';

DROP TABLE IF EXISTS `out_box_item`;
CREATE TABLE `out_box_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `box_id` bigint unsigned NOT NULL,
  `epc` varchar(32) NOT NULL, `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_box_epc` (`box_id`,`epc`), KEY `idx_epc` (`epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='装箱明细';


-- =============================================================================
-- 08 调拨与门店域 st_*
-- =============================================================================

DROP TABLE IF EXISTS `st_transfer`;
CREATE TABLE `st_transfer` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `transfer_no` varchar(32) NOT NULL COMMENT 'TR-8821',
  `transfer_type` varchar(16) NOT NULL DEFAULT 'wh_to_store' COMMENT 'wh_to_store总仓到门店/store_to_store店间/store_to_wh门店退仓/wh_to_wh仓间',
  `from_type` varchar(16) NOT NULL DEFAULT 'warehouse', `from_id` bigint unsigned NOT NULL,
  `to_type` varchar(16) NOT NULL DEFAULT 'store', `to_id` bigint unsigned NOT NULL,
  `to_code` varchar(64) NOT NULL DEFAULT '' COMMENT 'SH-01 展示',
  `to_name` varchar(128) NOT NULL DEFAULT '' COMMENT '上海南京路店',
  `order_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT '关联出库单',
  `wave_id` bigint unsigned NOT NULL DEFAULT 0, `shipment_id` bigint unsigned NOT NULL DEFAULT 0,
  `piece_qty` int NOT NULL DEFAULT 0 COMMENT '件数（120件）',
  `received_qty` int NOT NULL DEFAULT 0, `diff_qty` int NOT NULL DEFAULT 0,
  `eta` datetime DEFAULT NULL COMMENT '预计明日 10:00 到达',
  `carrier_id` bigint unsigned NOT NULL DEFAULT 0, `waybill_no` varchar(64) NOT NULL DEFAULT '',
  `status` varchar(24) NOT NULL DEFAULT 'pending' COMMENT 'pending待出库/picking备货中/shipped已发货/in_transit运输中/arrived待收货/received已完成/diff差异待处理/cancelled取消',
  `creator_id` bigint unsigned NOT NULL DEFAULT 0, `operator_id` bigint unsigned NOT NULL DEFAULT 0,
  `shipped_at` datetime DEFAULT NULL, `received_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_transfer_no` (`transfer_no`),
  KEY `idx_to` (`to_type`,`to_id`,`status`), KEY `idx_from` (`from_type`,`from_id`),
  KEY `idx_status` (`status`,`eta`), KEY `idx_wave` (`wave_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='调拨单（FR-ST-01）';

DROP TABLE IF EXISTS `st_transfer_item`;
CREATE TABLE `st_transfer_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `transfer_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `sku_id` bigint unsigned NOT NULL,
  `plan_qty` int NOT NULL DEFAULT 0, `shipped_qty` int NOT NULL DEFAULT 0, `received_qty` int NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_transfer_sku` (`transfer_id`,`sku_id`), KEY `idx_sku` (`sku_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='调拨明细';

DROP TABLE IF EXISTS `st_location`;
CREATE TABLE `st_location` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `store_id` bigint unsigned NOT NULL,
  `code` varchar(32) NOT NULL COMMENT 'floor卖场/backstore后仓/fitting试衣间/defect次品暂存',
  `name` varchar(64) NOT NULL,
  `is_display` tinyint NOT NULL DEFAULT 1 COMMENT '是否陈列位（缺码预警按陈列位判）',
  `sort` int NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_store_code` (`store_id`,`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='门店库位（陈列/后仓/试衣间）';

DROP TABLE IF EXISTS `st_sale`;
CREATE TABLE `st_sale` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `store_id` bigint unsigned NOT NULL,
  `source` varchar(16) NOT NULL DEFAULT 'pos' COMMENT 'pos门店收银/ec电商/manual手工',
  `order_no` varchar(64) NOT NULL COMMENT '外部销售单号',
  `line_no` int NOT NULL DEFAULT 1,
  `sku_id` bigint unsigned NOT NULL, `epc` varchar(32) NOT NULL DEFAULT '' COMMENT 'POS 无 EPC 时为空，走 SKU 核销',
  `qty` int NOT NULL DEFAULT 1,
  `amount` decimal(12,2) NOT NULL DEFAULT 0.00 COMMENT '成交金额',
  `discount` decimal(12,2) NOT NULL DEFAULT 0.00,
  `cashier` varchar(64) NOT NULL DEFAULT '',
  `sale_time` datetime NOT NULL,
  `sync_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_src_order_line` (`source`,`order_no`,`line_no`),
  KEY `idx_store_time` (`store_id`,`sale_time`), KEY `idx_sku_time` (`sku_id`,`sale_time`), KEY `idx_epc` (`epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='销售流水（POS/OMS 回传，核销库存）';

DROP TABLE IF EXISTS `st_fitting_log`;
CREATE TABLE `st_fitting_log` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `store_id` bigint unsigned NOT NULL,
  `fitting_room` varchar(32) NOT NULL DEFAULT '' COMMENT '试衣间编号',
  `epc` varchar(32) NOT NULL, `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `product_id` bigint unsigned NOT NULL DEFAULT 0,
  `in_time` datetime NOT NULL, `out_time` datetime DEFAULT NULL,
  `duration_s` int NOT NULL DEFAULT 0 COMMENT '停留秒数',
  `converted` tinyint NOT NULL DEFAULT 0 COMMENT '是否最终购买',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_store_sku_time` (`store_id`,`sku_id`,`in_time`), KEY `idx_epc` (`epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='试衣间读取（高试穿低转化分析）';

DROP TABLE IF EXISTS `st_return`;
CREATE TABLE `st_return` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `return_no` varchar(32) NOT NULL COMMENT 'RET-992',
  `store_id` bigint unsigned NOT NULL,
  `return_type` varchar(16) NOT NULL DEFAULT 'customer' COMMENT 'customer顾客退货/quality质量退货/transfer_back调拨退回',
  `source_order_no` varchar(64) NOT NULL DEFAULT '' COMMENT '原销售单号',
  `sku_qty` int NOT NULL DEFAULT 0 COMMENT '涉及 SKU 数',
  `piece_qty` int NOT NULL DEFAULT 0 COMMENT '件数（顾客退货 2 件）',
  `accepted_qty` int NOT NULL DEFAULT 0, `rebind_qty` int NOT NULL DEFAULT 0 COMMENT '重新绑定上架',
  `defect_qty` int NOT NULL DEFAULT 0 COMMENT '污损退回总仓',
  `state` varchar(24) NOT NULL DEFAULT 'pending' COMMENT 'pending待质检/processing处理中/rebooking质检无损重绑中/returned_w已退回总仓/completed完成/rejected拒绝',
  `handler_id` bigint unsigned NOT NULL DEFAULT 0, `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `finished_at` datetime DEFAULT NULL,
  `remark` varchar(255) NOT NULL DEFAULT '' COMMENT '污损 1 件，已解绑 RFID 打包退回次品区',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_return_no` (`return_no`),
  KEY `idx_store_state` (`store_id`,`state`), KEY `idx_source` (`source_order_no`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='门店退换货单（FR-ST-07）';

DROP TABLE IF EXISTS `st_return_item`;
CREATE TABLE `st_return_item` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `return_id` bigint unsigned NOT NULL,
  `epc` varchar(32) NOT NULL COMMENT '原 EPC',
  `new_epc` varchar(32) NOT NULL DEFAULT '' COMMENT '重新绑定后的新 EPC',
  `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `qc_result` varchar(16) NOT NULL DEFAULT '' COMMENT '无损good/污损defect/待检pending',
  `action` varchar(16) NOT NULL DEFAULT '' COMMENT 'rebind重新上架/return_wh退回总仓/scrap报废',
  `approver_id` bigint unsigned NOT NULL DEFAULT 0 COMMENT 'EPC 复用需主管审批（业务规则6）',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_return_epc` (`return_id`,`epc`), KEY `idx_new_epc` (`new_epc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='退换货明细（解绑/重绑留痕）';

DROP TABLE IF EXISTS `st_alert`;
CREATE TABLE `st_alert` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `alert_type` varchar(24) NOT NULL COMMENT 'size_gap陈列缺码/high_fit_low_convert高试穿低转化/low_stock库存不足/stock_diff盘点差异/aging库龄超期',
  `level` tinyint NOT NULL DEFAULT 2 COMMENT '1提示2警告3严重',
  `owner_type` varchar(16) NOT NULL DEFAULT 'store', `owner_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0, `sku_id` bigint unsigned NOT NULL DEFAULT 0,
  `size_code` varchar(16) NOT NULL DEFAULT '' COMMENT '缺失尺码 M/L',
  `message` varchar(500) NOT NULL DEFAULT '' COMMENT 'AW26-JK-01 (黑色) 卖场缺 M、L 码，请从后仓补货',
  `metric_json` text COMMENT '计算快照：{display_qty,back_qty,fit_count,sale_count}',
  `status` varchar(16) NOT NULL DEFAULT 'open' COMMENT 'open/processing处理中/resolved已解决/ignored忽略',
  `ref_biz_type` varchar(24) NOT NULL DEFAULT '' COMMENT 'replenish/receive/count',
  `ref_biz_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), KEY `idx_owner_status` (`owner_type`,`owner_id`,`status`),
  KEY `idx_type_time` (`alert_type`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='门店预警（缺码/试穿转化/盘差）';

DROP TABLE IF EXISTS `st_replenish`;
CREATE TABLE `st_replenish` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `task_no` varchar(32) NOT NULL,
  `store_id` bigint unsigned NOT NULL,
  `alert_id` bigint unsigned NOT NULL DEFAULT 0,
  `product_id` bigint unsigned NOT NULL DEFAULT 0, `sku_id` bigint unsigned NOT NULL,
  `from_st_location` varchar(32) NOT NULL DEFAULT 'backstore',
  `to_st_location` varchar(32) NOT NULL DEFAULT 'floor',
  `plan_qty` int NOT NULL DEFAULT 0, `done_qty` int NOT NULL DEFAULT 0,
  `status` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/doing/done/cancelled',
  `operator_id` bigint unsigned NOT NULL DEFAULT 0, `device_id` bigint unsigned NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_task_no` (`task_no`), KEY `idx_store_status` (`store_id`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='补货任务（一键从预警生成）';


-- =============================================================================
-- 09 报表汇总域 rpt_*
-- =============================================================================

DROP TABLE IF EXISTS `rpt_daily_owner`;
CREATE TABLE `rpt_daily_owner` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `stat_date` date NOT NULL,
  `owner_type` varchar(16) NOT NULL, `owner_id` bigint unsigned NOT NULL,
  `in_qty` int NOT NULL DEFAULT 0 COMMENT '入库件数（今日入库 45,280）',
  `out_qty` int NOT NULL DEFAULT 0 COMMENT '出库件数',
  `sale_qty` int NOT NULL DEFAULT 0, `return_qty` int NOT NULL DEFAULT 0,
  `diff_qty` int NOT NULL DEFAULT 0 COMMENT '差异件数（绝对值合计）',
  `count_task_count` int NOT NULL DEFAULT 0, `count_accuracy` decimal(6,4) NOT NULL DEFAULT 0.0000 COMMENT '盘点准确率',
  `stock_qty` int NOT NULL DEFAULT 0 COMMENT '日末账面库存',
  `in_amount` decimal(14,2) NOT NULL DEFAULT 0.00, `out_amount` decimal(14,2) NOT NULL DEFAULT 0.00,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_date_owner` (`stat_date`,`owner_type`,`owner_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='仓库/门店日汇总（看板走汇总表，避免扫流水）';

DROP TABLE IF EXISTS `rpt_daily_sku`;
CREATE TABLE `rpt_daily_sku` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `stat_date` date NOT NULL,
  `owner_type` varchar(16) NOT NULL, `owner_id` bigint unsigned NOT NULL,
  `product_id` bigint unsigned NOT NULL DEFAULT 0, `sku_id` bigint unsigned NOT NULL,
  `in_qty` int NOT NULL DEFAULT 0, `out_qty` int NOT NULL DEFAULT 0,
  `sale_qty` int NOT NULL DEFAULT 0, `stock_qty` int NOT NULL DEFAULT 0,
  `locked_qty` int NOT NULL DEFAULT 0, `diff_qty` int NOT NULL DEFAULT 0,
  `fit_count` int NOT NULL DEFAULT 0 COMMENT '试穿次数（门店）',
  `aging_days` int NOT NULL DEFAULT 0 COMMENT '库龄天',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_date_owner_sku` (`stat_date`,`owner_type`,`owner_id`,`sku_id`),
  KEY `idx_date_product` (`stat_date`,`product_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='SKU 日快照（动销/滞销/库龄报表）';

DROP TABLE IF EXISTS `rpt_epc_stat`;
CREATE TABLE `rpt_epc_stat` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `stat_date` date NOT NULL,
  `bound_total` bigint NOT NULL DEFAULT 0 COMMENT '活跃 EPC 总量（看板 1.24M）',
  `new_bound_qty` int NOT NULL DEFAULT 0 COMMENT '当日新发码',
  `sold_qty` int NOT NULL DEFAULT 0, `unbound_qty` int NOT NULL DEFAULT 0, `lost_qty` int NOT NULL DEFAULT 0,
  `read_count` bigint NOT NULL DEFAULT 0 COMMENT '当日读取条数',
  `miss_rate` decimal(6,4) NOT NULL DEFAULT 0.0000 COMMENT '漏读率',
  `stray_rate` decimal(6,4) NOT NULL DEFAULT 0.0000 COMMENT '串读率',
  `device_online` int NOT NULL DEFAULT 0 COMMENT '在线设备数（42）',
  `device_total` int NOT NULL DEFAULT 0 COMMENT '设备总数（45）',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`), UNIQUE KEY `uk_stat_date` (`stat_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 ROW_FORMAT=DYNAMIC COMMENT='RFID 健康度日汇总';


-- =============================================================================
-- 10 初始数据（最小可用集，密码哈希请用 php think user:passwd 生成后替换）
-- =============================================================================

INSERT INTO `sys_role` (`code`,`name`,`data_scope`,`remark`) VALUES
 ('admin','系统管理员','all','全部数据'),
 ('wh_manager','仓库主管','warehouse','本仓库'),
 ('receiver','收货作业员','warehouse','本仓库'),
 ('checker','分拣复核员','warehouse','本仓库'),
 ('store_manager','门店店长','store','本门店'),
 ('clerk','门店店员','store','本门店');

INSERT INTO `sys_permission` (`parent_id`,`name`,`code`,`type`,`path`,`icon`,`level`,`sort`) VALUES
 (0,'数据看板','dashboard','menu','/dashboard','📊',1,10),
 (0,'商品与RFID','master','menu','/master','👕',1,20),
 (0,'通道门入库','inbound','menu','/inbound','📥',1,30),
 (0,'库存与盘点','inventory','menu','/inventory','📦',1,40),
 (0,'分拣与出库','outbound','menu','/outbound','🚚',1,50),
 (0,'门店协同','store','menu','/store','🏬',1,60),
 (0,'设备管理','device','menu','/device','🖥',1,70),
 (0,'系统管理','system','menu','/system','⚙',1,80),
 (2,'新增SPU','master:spu:create','button','', '',2,21),
 (2,'发码打印','master:epc:print','button','','',2,22),
 (2,'色码矩阵','master:sku:matrix','button','','',2,23),
 (3,'收货确认','inbound:receipt:confirm','button','','',2,31),
 (3,'差异处理','inbound:diff:handle','button','','',2,32),
 (4,'新建盘点','inventory:count:create','button','','',2,41),
 (4,'差异审核','inventory:count:audit','button','','',2,42),
 (5,'格口重置','outbound:wall:reset','button','','',2,51),
 (5,'装车发货','outbound:shipment:create','button','','',2,52);

INSERT INTO `sys_dict_type` (`type_code`,`name`,`remark`) VALUES
 ('season','季节','2026秋/2026冬'),
 ('wave','波段','波1/波2/波3'),
 ('gender','性别','男女童通用'),
 ('stock_type','库存类型','良品/冻结/次品/待检/在途'),
 ('carrier','承运商','顺丰/京东/自送'),
 ('diff_cause','差异原因','未盘/遗失/被盗/少发/未入账'),
 ('scrap_reason','报废原因','污损/质量/过季'),
 ('device_type','设备类型','通道门/桌面机/打印机/PDA/分拣墙/试衣间');

INSERT INTO `sys_dict_item` (`type_code`,`item_code`,`item_label`,`ext_value`,`sort`) VALUES
 ('season','2026AW','2026秋','',10),('season','2026SS','2026春夏','',20),
 ('wave','W1','波1','',10),('wave','W2','波2','',20),('wave','W3','波3','',30),
 ('stock_type','normal','良品','',10),('stock_type','frozen','冻结','',20),
 ('stock_type','defect','次品','',30),('stock_type','quarantine','待检','',40),('stock_type','transit','在途','',50),
 ('diff_cause','unattended','未盘','',10),('diff_cause','lost','遗失','',20),('diff_cause','stolen','被盗','',30),
 ('diff_cause','ship_short','少发','',40),('diff_cause','not_booked','退货未入账','',50),
 ('scrap_reason','damaged','污损','',10),('scrap_reason','quality','质量问题','',20),('scrap_reason','offline','过季','',30),
 ('device_type','gate','RFID 通道门','',10),('device_type','desktop','RFID 桌面机','',20),
 ('device_type','printer','RFID 打印机','',30),('device_type','pda','手持机 PDA','',40),
 ('device_type','sortwall','智能分拣墙','',50),('device_type','fitting','试衣间读写器','',60);

INSERT INTO `md_color` (`color_code`,`color_name`,`hex_value`,`sort`) VALUES
 ('BK','黑色','#111111',10),('KH','卡其','#c3a97a',20),('NV','藏青','#1f2a44',30),('WH','白色','#f5f5f5',40);

INSERT INTO `md_size` (`size_code`,`size_name`,`size_group`,`sort`) VALUES
 ('XS','XS','adult',10),('S','S','adult',20),('M','M','adult',30),('L','L','adult',40),('XL','XL','adult',50),('XXL','XXL','adult',60);

INSERT INTO `md_warehouse` (`code`,`name`,`type`,`region`) VALUES
 ('WH01','总仓','center','华东'),
 ('WH02','华东分仓','sort','华东');

INSERT INTO `md_area` (`warehouse_id`,`code`,`name`,`type`,`turnover`) VALUES
 (1,'A','A区 秋季新品','storage','fast'),
 (1,'B','B区 夏季滞销','storage','slow'),
 (1,'R','退货暂存区','return','normal'),
 (1,'D','次品区','defect','normal'),
 (1,'S','待发运区','staging','fast');

INSERT INTO `md_store` (`code`,`name`,`warehouse_id`,`region`) VALUES
 ('SH-01','上海南京路旗舰店',1,'上海区'),('SH-02','上海静安店',1,'上海区'),
 ('BJ-01','北京三里屯店',1,'北京区'),('BJ-02','北京国贸店',1,'北京区'),
 ('GZ-01','广州天河城店',1,'广州区'),('SZ-01','深圳万象城店',1,'深圳区'),
 ('HZ-01','杭州湖滨店',1,'杭州区'),('CD-01','成都春熙路店',1,'成都区'),
 ('WH-01','武汉江汉路店',1,'武汉区'),('NJ-01','南京新街口店',1,'南京区'),
 ('XA-01','西安钟楼店',1,'西安区'),('CQ-01','重庆解放碑店',1,'重庆区');

INSERT INTO `md_supplier` (`code`,`name`,`tolerance_qty`) VALUES
 ('SUP01','东莞制衣厂',0),('SUP02','杭州丝绸',0),('SUP03','广州牛仔',2);

INSERT INTO `md_carrier` (`code`,`name`) VALUES ('SF','顺丰速运'),('JD','京东物流'),('SELF','自送');

INSERT INTO `rfid_epc_rule`
 (`rule_code`,`name`,`rule_type`,`epc_length`,`header_hex`,`company_prefix`,`serial_min`,`serial_max`,`status`) VALUES
 ('R-UPC-SN','UPC + 序列号','upc_sn',24,'3004','0860000',1,99999999,'active'),
 ('R-EAN13-SN','EAN-13 + 序列号','ean13_sn',24,'3004','0860000',1,99999999,'active'),
 ('R-CUSTOM-96','自定义 96bit 分段','custom_96',24,'3004','086',1,99999999,'active');

INSERT INTO `rfid_tag_template` (`code`,`name`,`lang`,`width_mm`,`height_mm`,`content`,`variables`) VALUES
 ('TPL-DIAO-60x30','吊牌 60x30 标准','ZPL',60,30,
  '^XA^FO40,40^BY2^BUN,80,Y^FD{BARCODE}^FS^FO40,140^AAN,24^FD{SKU_CODE}^FS^FO40,175^AAN,20^FD{NAME} {COLOR} {SIZE}^FS^FO40,210^AAN,20^FD¥{PRICE}^FS^FO40,250^AAN,16^FDEPC {EPC}^FS^XZ',
  'BARCODE,SKU_CODE,NAME,COLOR,SIZE,PRICE,EPC');

INSERT INTO `sys_serial_rule` (`biz_type`,`prefix`,`date_format`,`seq_length`,`sample`) VALUES
 ('ASN','ASN','Ymd',2,'ASN-20261003-01'),
 ('RECEIPT','RCT','Ymd',3,'RCT-20261003-001'),
 ('WAVE','WAVE','md',1,'WAVE-1003-A'),
 ('CHECK','CHK','Ymd',3,'CHK-20261003-001'),
 ('SHIPMENT','SHP','Ymd',3,'SHP-20261003-001'),
 ('TRANSFER','TR','',4,'TR-8821'),
 ('RETURN','RET','',3,'RET-992'),
 ('COUNT','INV','md',1,'INV-A-1003'),      -- 区域段 A 由 cnt_task.area_code 注入（FR-IV-03 单号 INV-{区}MMDD）
 ('ADJUST','ADJ','Ymd',3,'ADJ-20261003-001'),
 ('PRINT','PRT','Ymd',4,'PRT-20261003-0001'),
 ('MOVEMENT','MOV','Ymd',3,'MOV-20261003-001'),
 ('DISCREPANCY','DISC','Ymd',3,'DISC-20261003-001'),
 ('PUTAWAY','PUT','Ymd',3,'PUT-20261003-001'),
 ('REPLENISH','REP','Ymd',3,'REP-20261003-001'),
 ('BOX','BOX','Ymd',4,'BOX-20261003-0001');

INSERT INTO `sys_config` (`group_code`,`config_key`,`config_value`,`value_type`,`name`,`remark`) VALUES
 ('rfid','rfid.dedup_window_s','3','int','读取去重窗口(秒)','同一设备同一 EPC 窗口内计 1 件（RF-06）'),
 ('rfid','rfid.heartbeat_offline_s','120','int','心跳判离线阈值(秒)','FR-DV-02'),
 ('rfid','rfid.gate_min_duration_s','6','int','过门最短读取时长(秒)','RF-04'),
 ('rfid','rfid.rssi_min_default','-70','int','默认 RSSI 门限(dBm)','串读抑制 RF-05'),
 ('rfid','rfid.read_log_keep_days','90','int','原始日志保留天数','R4'),
 ('inventory','inventory.accuracy_formula','sku_hit_rate','string','盘点准确率口径','命中SKU/应盘SKU（业务规则2）'),
 ('inventory','inventory.blind_count_default','1','bool','默认盲盘','FR-IV-04'),
 ('inventory','inventory.aging_warn_days','120','int','库龄预警天数','FR-IV-08'),
 ('inbound','inbound.diff_tolerance_default','0','int','过门差异默认容差(件)','业务规则1，默认零容差'),
 ('inbound','inbound.stray_auto_reject','0','bool','串读件自动拒收开关','FR-IN-04，默认转异常件人工归属'),
 ('outbound','outbound.sort_skip_check','0','bool','允许跳过复核装车','FR-OB-05，生产必须为 0'),
 ('store','store.size_gap_check','1','bool','陈列缺码预警开关','FR-ST-04'),
 ('store','store.fit_convert_ratio','0.10','float','试穿转化率阈值','低于该值触发预警（FR-ST-05）'),
 ('system','system.pwd_bcrypt_cost','12','int','密码 cost','');

INSERT INTO `dev_device`
 (`device_code`,`name`,`device_type`,`driver`,`warehouse_id`,`location_text`,`online_status`,`status`) VALUES
 ('GATE-A01','1号月台 RFID 通道门','gate','sim',1,'总仓 1号月台','online','active'),
 ('GATE-A02','2号月台 RFID 通道门','gate','sim',1,'总仓 2号月台','online','active'),
 ('DESK-QC01','质检打包台桌面机','desktop','sim',1,'质检打包台','online','active'),
 ('PRINT-01','标签房打印机','printer','sim',1,'标签房','no_paper','active'),
 ('PDA-05','盘点组 A 手持机','pda','sim',1,'盘点组 A','charging','active'),
 ('WALL-01','RFID 智能分拣墙','sortwall','sim',1,'分拣区','online','active');


-- 管理员账号：请在服务端执行 `php think user:create admin` 生成 bcrypt 后写入，
-- 切勿在脚本里存放明文或示例哈希。
-- INSERT INTO `sys_user` (`username`,`password`,`real_name`,`user_type`,`warehouse_id`,`status`) VALUES ('admin','<bcrypt>','系统管理员','admin',1,'active');

SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- 附：容量与索引提示
--   rfid_tag        1.24M 行，uk_epc 单列唯一；查询主路径 (sku_id,status) / (owner_type,owner_id,status)
--   rfid_read_log   日增 ~500万：按 read_time 做 RANGE 分区（需将 created_at 并入主键则改用月表 rfid_read_log_YYYYMM）
--                   或 90 天归档到 rfid_read_log_arch（同结构）+ DROP PARTITION
--   inv_transaction 只增不改不删；对账脚本 SUM(change_qty) GROUP BY (owner,sku) == inv_stock.qty
--   st_sale         外部回传，唯一键 (source,order_no,line_no) 天然幂等
-- =============================================================================
