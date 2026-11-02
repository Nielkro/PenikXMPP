using Sqlite;

namespace Qlite {

public class UpsertBuilder : StatementBuilder {
    // INTO [...]
    private Table table;
    private string table_name;

    // VALUES [...]
    private StatementBuilder.AbstractField[] keys = {};
    private StatementBuilder.AbstractField[] fields = {};

    internal UpsertBuilder(Database db, Table table) {
        base(db);
        this.table = table;
        this.table_name = table.name;
    }

    public UpsertBuilder value<T>(Column<T> column, T value, bool key = false) {
        if (key) {
            keys += new Field<T>(column, value);
        } else {
            fields += new Field<T>(column, value);
        }
        return this;
    }

    public UpsertBuilder value_null<T>(Column<T> column, bool key = false) {
        if (column.not_null) error("Can't set non-null column %s to null", column.name);
        if (key) {
            keys += new NullField<T>(column);
        } else {
            fields += new NullField<T>(column);
        }
        return this;
    }

    internal override Statement prepare() {
        return prepare_upsert();
    }

    internal Statement prepare_upsert() {
        var unique_fields = new StringBuilder();
        var unique_values = new StringBuilder();
        var update_fields = new StringBuilder();
        var update_values = new StringBuilder();
        var update_fields_vals = new StringBuilder();

        for (int i = 0; i < keys.length; i++) {
            if (i != 0) {
                unique_fields.append(", ");
                unique_values.append(", ");
            }
            unique_fields.append(keys[i].column.name);
            unique_values.append("?");
        }

        for (int i = 0; i < fields.length; i++) {
            if (i != 0) {
                update_fields.append(", ");
                update_values.append(", ");
                update_fields_vals.append(", ");
            }
            update_fields.append(fields[i].column.name);
            update_values.append("?");
            update_fields_vals.append(fields[i].column.name).append("=excluded.").append(fields[i].column.name);
        }

        string sql = @"INSERT INTO $table_name ($(unique_fields.str), $(update_fields.str)) VALUES ($(unique_values.str), $(update_values.str)) " +
                @"ON CONFLICT ($(unique_fields.str)) DO UPDATE SET $(update_fields_vals.str)";

        Statement stmt = db.prepare(sql);
        for (int i = 0; i < keys.length; i++) {
            keys[i].bind(stmt, i + 1);
        }
        for (int i = 0; i < fields.length; i++) {
            fields[i].bind(stmt, i + keys.length + 1);
        }

        return stmt;
    }

    public int64 perform_checked() throws Error {
        int result = prepare_upsert().step();
        if (result != DONE) {
            throw new GLib.Error(
                Quark.from_string("qlite-write-error"),
                result,
                "SQLite error: %d - %s".printf(db.errcode(), db.errmsg()));
        }
        return db.last_insert_rowid();
    }

    public int64 perform() {
        try {
            return perform_checked();
        } catch (Error e) {
            critical("%s", e.message);
            return db.last_insert_rowid();
        }
    }

}

}
