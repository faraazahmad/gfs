CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" INTEGER PRIMARY KEY, "inserted_at" TEXT);
CREATE TABLE IF NOT EXISTS "file" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "path" TEXT, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE IF NOT EXISTS "node" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "identifier" TEXT, "alive" INTEGER, "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE UNIQUE INDEX "node_identifier_index" ON "node" ("identifier");
INSERT INTO schema_migrations VALUES(20240923104742,'2025-01-04T21:12:59');
INSERT INTO schema_migrations VALUES(20240923104759,'2025-01-04T21:12:59');
INSERT INTO schema_migrations VALUES(20240923110930,'2025-01-04T21:12:59');
