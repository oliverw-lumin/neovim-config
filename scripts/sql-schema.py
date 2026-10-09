"""Read CREATE TABLE metadata only; never execute SQL or connect to a database."""
import json
import sys
import uuid
from pathlib import Path

import sqlglot
from sqlglot import exp
from sqlglot.tokens import TokenType


def catalog(path):
    path = Path(path).resolve()
    text = path.read_text()
    # ClickHouse's query-result export can omit semicolons between CREATEs.
    # Token boundaries avoid splitting inside quoted names, strings or comments.
    tokens = sqlglot.tokenize(text, read="clickhouse")
    starts = [t.start for t in tokens if t.token_type == TokenType.CREATE]
    tables = []
    for start, end in zip(starts, starts[1:] + [len(text)]):
        stmt = sqlglot.parse_one(text[start:end], read="clickhouse")
        if not isinstance(stmt, exp.Create) or not isinstance(stmt.this, exp.Schema):
            raise ValueError("schema.sql must contain CREATE TABLE definitions with explicit columns")
        table = stmt.this.this
        if not isinstance(table, exp.Table):
            raise ValueError("Expected a table name")
        columns = []
        for col in stmt.this.expressions:
            if not isinstance(col, exp.ColumnDef):
                continue
            kind = col.args.get("kind")
            columns.append({
                "name": col.name,
                "data_type": kind.sql(dialect="clickhouse") if kind else "unknown",
                "nullable": not any(isinstance(c.args.get("kind"), exp.NotNullColumnConstraint)
                                    for c in col.args.get("constraints", [])),
                "source_location": [path.as_uri(), text.count("\n", 0, start)],
            })
        tables.append({
            "name": table.sql(dialect="clickhouse"),
            "columns": columns,
            "source_location": [path.as_uri(), text.count("\n", 0, start)],
        })
    if not tables and text.strip():
        raise ValueError("No CREATE TABLE definitions found in schema.sql")
    return {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, path.as_uri())),
            "database": "", "tables": tables, "functions": [], "source_uri": path.as_uri()}


if __name__ == "__main__":
    try:
        print(json.dumps(catalog(sys.argv[1])))
    except Exception as error:
        sys.exit(f"Cannot read SQL schema: {error}")
