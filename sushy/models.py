import os, sys, logging
from peewee import *
from playhouse.sqlite_ext import *
import datetime

log = logging.getLogger()

# Database models for metadata caching and full text indexing using SQLite3 (handily beats Whoosh and makes for a single index file)

# TODO: port these to Hy (if at all possible given that this uses inner classes and stuff)

db = SqliteExtDatabase(os.environ['DATABASE_PATH'], threadlocals=True)

class Entry(Model):
    """Metadata table"""
    id          = CharField(primary_key=True)
    title       = CharField()
    tags        = CharField()
    mtime       = DateTimeField()

    class Meta:
        database = db


class FTSEntry(FTSModel):
    """Full text indexing table"""
    entry = ForeignKeyField(Entry, primary_key=True)
    content = TextField()

    class Meta:
        database = db


def create_db():
    try:
        Entry.create_table()
        FTSEntry.create_table()
    except OperationalError as e:
        log.info(e)
        FTSEntry.optimize()



def add_entry(**kwargs):
    with db.transaction():
        try:
            entry = Entry.create(**kwargs)
        except IntegrityError:
            entry = Entry.get(Entry.id == kwargs["id"])
        content = []
        for k in ['title', 'body', 'tags']:
            if kwargs[k]:
                content.append(kwargs[k])
            FTSEntry.delete().where(FTSEntry.entry == entry).execute()
            FTSEntry.create(entry = entry, content = '\n'.join(content))


def get_entry(id):
    return Entry.get(Entry.id == id)._data


def get_latest(limit=20):
    query = (Entry.select()
                  .where(Entry.mtime >= (datetime.datetime.now() + datetime.timedelta(weeks=-12)))
                  .order_by(SQL('mtime').desc())
                  .limit(limit)
                  .dicts())

    for entry in query:
        yield entry


def do_query(qstring, limit=50):
    query = (FTSEntry.select(Entry,
                             FTSEntry,
                             FTSEntry.bm25(FTSEntry.content).alias('score'))
                     .join(Entry)
                     .where(FTSEntry.match(qstring))
                     .order_by(SQL('score').desc())
                     .limit(limit))

    for entry in query:
        yield {
            "title"       : entry.entry.title,
            "score"       : round(entry.score, 2),
            "mtime"       : entry.entry.mtime,
            "tags"        : entry.entry.tags,
            "id"          : entry.entry.id
        }
