"""Olist 数据清洗与入库模块。

把 Notebook 中「读取原始 CSV → 时间字段转 datetime → 去重 / 缺失值处理 →
导出 data/processed/*.csv → 写入 data/olist.db」的全部逻辑收敛到这里，
Notebook 只负责调用与展示结果，保持清爽。

用法
----
在 Notebook 或其他脚本中一次性重跑 6 张表：

    from scripts.data_cleaning import process_all_data
    cleaned = process_all_data()

也可分阶段调用（对应 Notebook 的第一、第二阶段）：

    from scripts.data_cleaning import process_orders, process_secondary_tables
    orders = process_orders()             # 阶段一：订单主表
    tables = process_secondary_tables()   # 阶段二：其余 5 张核心表

或在命令行独立运行（路径按项目根目录解析，与当前工作目录无关）：

    python scripts/data_cleaning.py
"""

from __future__ import annotations

from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

# 项目根目录：本文件位于 <项目根>/scripts/data_cleaning.py，取上两级即项目根。
# 这样无论从哪个目录启动脚本或 Notebook，数据路径都能正确定位。
BASE_DIR = Path(__file__).resolve().parents[1]

RAW_DIR = BASE_DIR / "data" / "raw"          # 原始 CSV 目录
PROCESSED_DIR = BASE_DIR / "data" / "processed"  # 清洗后 CSV 目录
DB_PATH = BASE_DIR / "data" / "olist.db"     # SQLite 数据库文件

# ===== 阶段一：订单主表 =====
ORDERS_FILE = "olist_orders_dataset.csv"
ORDERS_TABLE = "orders_cleaned"

# 需要转成 datetime 的 5 个业务时间字段
ORDERS_DATETIME_COLS = [
    "order_purchase_timestamp",
    "order_approved_at",
    "order_delivered_carrier_date",
    "order_delivered_customer_date",
    "order_estimated_delivery_date",
]

# 缺失即无法使用的关键字段
ORDERS_KEY_COLS = ["order_id", "customer_id", "order_status", "order_purchase_timestamp"]

# ===== 阶段二：其余 5 张核心表 =====
# 配置驱动：新增表只需追加一条配置，无需改动处理逻辑
TABLES = [
    {
        "file": "olist_order_payments_dataset.csv",
        "table": "payments",
        "datetime_cols": [],                       # 支付表无需转换时间字段
    },
    {
        "file": "olist_order_items_dataset.csv",
        "table": "order_items",
        "datetime_cols": ["shipping_limit_date"],  # 卖家发货截止时间
    },
    {
        "file": "olist_order_reviews_dataset.csv",
        "table": "reviews",
        "datetime_cols": ["review_creation_date", "review_answer_timestamp"],
    },
    {
        "file": "olist_products_dataset.csv",
        "table": "products",
        "datetime_cols": [],                       # 商品表均为数值与文本字段
    },
    {
        "file": "product_category_name_translation.csv",
        "table": "category_translation",
        "datetime_cols": [],                       # 仅为品类名称映射表
    },
]

# 校验用：6 张表的完整清单（订单表 + 其余 5 张）
ALL_TABLES = [{"table": ORDERS_TABLE, "datetime_cols": ORDERS_DATETIME_COLS}, *TABLES]


def _rel_path(path: Path) -> str:
    """把绝对路径转成相对项目根目录的写法，日志更易读。"""
    try:
        return path.relative_to(BASE_DIR).as_posix()
    except ValueError:  # 路径不在项目根目录下（理论上不会发生）
        return str(path)


def get_engine(db_path: Path | None = None) -> Engine:
    """创建（或复用）SQLite 数据库引擎。"""
    return create_engine(f"sqlite:///{db_path or DB_PATH}")


def _ensure_output_dirs() -> None:
    """确保输出目录存在，重复执行不会报错。"""
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)


def process_orders(engine: Engine | None = None) -> pd.DataFrame:
    """阶段一：清洗订单主表，导出 CSV 并写入 SQLite，返回清洗后的 DataFrame。"""
    engine = engine or get_engine()
    _ensure_output_dirs()

    # ===== 读取原始数据 =====
    df = pd.read_csv(RAW_DIR / ORDERS_FILE)
    print(f"原始数据规模：{df.shape[0]} 行 × {df.shape[1]} 列")
    print(f"order_id 是否存在重复：{df['order_id'].duplicated().any()}")

    # 统一转换为 pandas 的 datetime 类型，无法解析的值会变成 NaT
    df[ORDERS_DATETIME_COLS] = df[ORDERS_DATETIME_COLS].apply(pd.to_datetime)

    # ===== 缺失值检查 =====
    missing = df.isna().sum()
    print("\n处理前缺失值统计：")
    print(missing[missing > 0])

    # ===== 缺失值处理（结合电商订单业务特点）=====
    # 1) 订单主键、客户 ID、状态、下单时间缺失时，订单无法归属或无法判断状态，直接删除；
    #    本数据集这几个字段实际无缺失。
    # 2) 审批/承运/签收时间缺失属于业务上的“尚未发生”（如已取消、未发货、未签收的订单），
    #    不能用中位数、前向填充等方式补齐，否则会凭空造出“已审批/已发货/已签收”的时间线，
    #    导致后续履约时长、延迟率等指标失真。因此保留 NaT（空值），
    #    后续分析时按 order_status 过滤或单独统计即可。
    df = df.dropna(subset=ORDERS_KEY_COLS).reset_index(drop=True)

    # 仅统计时间字段缺失率，便于后续判断有效样本量（不做填充）
    missing_rate = (df[ORDERS_DATETIME_COLS].isna().mean() * 100).round(2)
    print("各时间字段缺失率（%，保留空值）：")
    print(missing_rate)

    # ===== 保存清洗后的数据 =====
    # 输出 CSV：utf-8-sig 便于 Excel 直接打开且不乱码
    out_path = PROCESSED_DIR / f"{ORDERS_TABLE}.csv"
    df.to_csv(out_path, index=False, encoding="utf-8-sig")
    print(f"\n已保存清洗后 CSV：{_rel_path(out_path)}")

    # 写入 SQLite；if_exists="replace" 表示表已存在时先删除再重建，保证重复运行安全
    df.to_sql(ORDERS_TABLE, engine, if_exists="replace", index=False)

    # 简单校验数据库中的行数
    db_rows = pd.read_sql(f"SELECT COUNT(*) AS cnt FROM {ORDERS_TABLE}", engine).loc[0, "cnt"]
    print(
        f"已写入 SQLite：{_rel_path(DB_PATH)} -> {ORDERS_TABLE}"
        f"（{db_rows:,} 行，与 DataFrame 一致：{db_rows == len(df)}）"
    )
    return df


def clean_and_load(cfg: dict, engine: Engine) -> pd.DataFrame:
    """读取单张原始表 → 时间字段转 datetime → 去重 → 存 CSV → 写入 SQLite。"""
    raw_path = RAW_DIR / cfg["file"]
    out_path = PROCESSED_DIR / f"{cfg['table']}_cleaned.csv"

    df = pd.read_csv(raw_path)
    raw_rows = len(df)

    # 时间字段转换：errors="coerce" 让无法解析的值变成 NaT，避免整列报错中断流程
    for col in cfg["datetime_cols"]:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce")

    # 剔除完全重复的行（所有字段取值都相同才算重复，不会误删同一订单的多条支付/明细）
    df = df.drop_duplicates().reset_index(drop=True)

    # 输出 CSV：utf-8-sig 便于 Excel 直接打开不乱码
    df.to_csv(out_path, index=False, encoding="utf-8-sig")

    # 写入 SQLite，表已存在时先删除再重建
    df.to_sql(cfg["table"], engine, if_exists="replace", index=False)

    print(
        f"表 {cfg['table']} 已成功入库：{len(df):,} 行 × {df.shape[1]} 列"
        f"（原始 {raw_rows:,} 行，去重 {raw_rows - len(df):,} 行），"
        f"CSV -> {_rel_path(out_path)}"
    )
    return df


def process_secondary_tables(engine: Engine | None = None) -> dict[str, pd.DataFrame]:
    """阶段二：批量清洗其余 5 张核心表，返回 {表名: DataFrame} 字典。"""
    engine = engine or get_engine()
    _ensure_output_dirs()

    cleaned = {}
    for cfg in TABLES:
        cleaned[cfg["table"]] = clean_and_load(cfg, engine)

    print("\n全部 5 张表处理完成。")
    return cleaned


def process_all_data(engine: Engine | None = None) -> dict[str, pd.DataFrame]:
    """主函数：一次性完成 6 张核心表的清洗与入库，返回 {表名: DataFrame} 字典。"""
    engine = engine or get_engine()

    cleaned = {ORDERS_TABLE: process_orders(engine)}
    cleaned.update(process_secondary_tables(engine))

    print("\n" + "=" * 66)
    print(f"全部 {len(cleaned)} 张表已清洗并写入 {_rel_path(DB_PATH)}")
    print("=" * 66)
    return cleaned


def verify_database(engine: Engine | None = None) -> None:
    """入库校验：核对每张表的行数、字段与时间字段样例。"""
    engine = engine or get_engine()

    print("=" * 66)
    print(f"入库校验：{_rel_path(DB_PATH)}")
    print("=" * 66)
    for cfg in ALL_TABLES:
        table = cfg["table"]
        cnt = pd.read_sql(f"SELECT COUNT(*) AS cnt FROM {table}", engine).loc[0, "cnt"]
        cols = pd.read_sql(f"SELECT * FROM {table} LIMIT 0", engine).columns.tolist()
        print(f"{table:<20} 行数={cnt:>7,}  字段={cols}")
        if cfg["datetime_cols"]:
            sample = pd.read_sql(
                f"SELECT {', '.join(cfg['datetime_cols'])} FROM {table} LIMIT 2", engine
            )
            print(sample.to_string(index=False))
        print()


if __name__ == "__main__":
    process_all_data()
    verify_database()
