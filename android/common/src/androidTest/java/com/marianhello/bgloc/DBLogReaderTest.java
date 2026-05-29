package com.marianhello.bgloc;

import android.content.Context;
import androidx.test.InstrumentationRegistry;
import androidx.test.runner.AndroidJUnit4;
import androidx.test.filters.SmallTest;

import com.marianhello.logging.DBLogReader;
import com.marianhello.logging.LogEntry;
import com.marianhello.logging.LoggerManager;

import junit.framework.Assert;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.slf4j.Logger;
import org.slf4j.event.Level;

import java.io.File;
import java.util.ArrayList;
import java.util.Collection;
import android.content.Context;

import ch.qos.logback.core.android.AndroidContextUtil;
import android.content.ContextWrapper;

@RunWith(AndroidJUnit4.class)
@SmallTest
public class DBLogReaderTest {
    private static final String TAG = "DBLogReaderTest";
    private Context mContext;

    @Before
    public void deleteDatabase() {
        LoggerManager.disableDBLogging();
        mContext = InstrumentationRegistry.getTargetContext();
        ContextWrapper contextWrapper = new ContextWrapper(mContext);
        AndroidContextUtil contextUtil = new AndroidContextUtil(contextWrapper);
        String dbPath = contextUtil.getDatabasePath(DBLogReader.DB_FILENAME);
        if (dbPath != null && !dbPath.isEmpty()) {
            new File(dbPath).delete();
        }
    }

    @Test
    public void testReadLogEntriesWithLimit() {
        LoggerManager.enableDBLogging();
        Logger logger = LoggerManager.getLogger(DBLogReaderTest.class);

        for (int i = 0; i < 100; i++) {
            logger.debug("Message #" + i);
        }

        DBLogReader logReader = new DBLogReader(mContext);
        Collection<LogEntry> entries = logReader.getEntries(10, 0, Level.DEBUG);
        Assert.assertEquals(10, entries.size());
    }

    @Test
    public void testReadLogEntriesWithOffset() {
        LoggerManager.enableDBLogging();
        Logger logger = LoggerManager.getLogger(DBLogReaderTest.class);

        for (int i = 0; i < 100; i++) {
            logger.debug("Message #" + i);
        }

        DBLogReader logReader = new DBLogReader(mContext);
        ArrayList<LogEntry> entries = (ArrayList) logReader.getEntries(10, 0, Level.DEBUG);
        LogEntry lastEntry = entries.get(entries.size() - 1);
        entries = (ArrayList) logReader.getEntries(10, lastEntry.getId(), Level.DEBUG);
        Assert.assertEquals(lastEntry.getId() - 1, entries.get(0).getId().intValue());
    }

    @Test
    public void testReadLogEntriesWithOffsetAsc() {
        LoggerManager.enableDBLogging();
        Logger logger = LoggerManager.getLogger(DBLogReaderTest.class);

        for (int i = 0; i < 100; i++) {
            logger.debug("Message #" + i);
        }

        DBLogReader logReader = new DBLogReader(mContext);
        ArrayList<LogEntry> entries = (ArrayList) logReader.getEntries(10, 0, Level.DEBUG);
        LogEntry lastEntry = entries.get(entries.size() - 1);
        entries = (ArrayList) logReader.getEntries(-10, lastEntry.getId(), Level.DEBUG);
        Assert.assertEquals(lastEntry.getId() + 1, entries.get(0).getId().intValue());
    }
}
