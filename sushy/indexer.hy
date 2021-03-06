(import
    [cProfile           [Profile]]
    [datetime           [datetime timedelta]]
    [hashlib            [sha1]]
    [json               [dumps]]
    [logging            [getLogger Formatter]]
    [newrelic           [agent]]
    [os                 [environ]]
    [os.path            [basename dirname join]]
    [pstats             [Stats]]
    [sushy.config       [*aliasing-chars* *base-filenames* *bind-address* *store-path* *timezone* *profiler*]]
    [sushy.models       [db add-wiki-links delete-wiki-page index-wiki-page init-db get-page-indexing-time]]
    [sushy.render       [render-page]]
    [sushy.store        [is-page? gen-pages get-page]]
    [sushy.transform    [apply-transforms count-images extract-internal-links extract-plaintext]]
    [sushy.utils        [parse-naive-date strip-timezone slug utc-date]]
    [time               [sleep time]]
    [watchdog.observers [Observer]]
    [watchdog.events    [FileSystemEventHandler]])

(setv log (getLogger --name--))

(def *logging-modulo* 100)

(defn transform-tags [line]
    ; expand tags to be "tag:value", which enables us to search for tags using FTS
    (let [[tags (.split (.strip line) ",")]]
        (if (!= tags [""])
            (.lower (.join ", " (sorted (list (set (map (fn [tag] (+ "tag:" (.strip tag))) tags))))))
            "")))


(defn hide-from-search? [headers]
    (reduce (fn [x y] (or x y))
        (map (fn [header]
                (if (and (in header headers)
                         (in (.lower (get headers header)) ["off" "no" "false"]))
                    true
                    false))
            ["x-index" "index" "search"])
        false))


(defn published? [headers]
    (reduce (fn [x y] (and x y))
        (map (fn [header]
                (if (and (in header headers)
                         (in (.lower (get headers header)) ["off" "no" "false"]))
                    false
                    true))
            ["visible" "published"])
        true))


(defn gather-item-data [item]
    ; Takes a map with basic item info and builds all the required indexing data
    (.debug log (:path item))
    (let [[pagename     (:path item)]
          [mtime        (:mtime item)]
          [mdate        (.fromtimestamp datetime (:mtime item))]
          [page         (get-page pagename)]
          [headers      (:headers page)]
          [doc          (apply-transforms (render-page page) pagename)]
          [plaintext    (extract-plaintext doc)]
          [word-count   (len (.split plaintext))]
          [image-count  (count-images doc)]
          [links        (extract-internal-links doc)]
          [pubtime      (parse-naive-date (.get headers "date") mdate *timezone*)]]
        {"name"     pagename
         "body"     (if (hide-from-search? headers) "" plaintext)
         "hash"     (.hexdigest (sha1 (.encode plaintext "utf-8")))
         "title"    (.get headers "title" "Untitled")
         "tags"     (transform-tags (.get headers "tags" ""))
         "pubtime"  (strip-timezone (utc-date pubtime))
         "mtime"    (strip-timezone (utc-date (parse-naive-date (.get headers "last-modified") pubtime *timezone*)))
         "idxtime"  mtime
         "readtime" (int (round (+ (* 12.0 image-count) (/ word-count 4.5))))
         "headers"  headers
         "links"    (list links)}))


(defn index-one [item]
    (try
        (let [[page    (.get item "name")]
              [headers (.get item "headers")]
              [links   (map (fn [l] {"page" page "link" l}) (.get item "links"))]]
            (if (published? headers)
                (do
                    (add-wiki-links links)
                    (apply index-wiki-page [] item))
                (delete-wiki-page page)))
        (catch [e Exception]
            (.warning log (% "%s:%s handling %s" (, (type e) e item))))))


(defn filesystem-walk [path &optional [suffix ""]]
    ; walk the filesystem and perform full-text and front matter indexing
    (let [[item-count 0]
          [skipped-count 0]]
        (for [item (gen-pages path)]
            (.debug log item)
            (if (= 0 (% item-count *logging-modulo*))
                (.info log (% "indexing %d" item-count)))
            (setv item-count (inc item-count))
            (.debug log (:path item))
            (setv idxtime (get-page-indexing-time (:path item)))
            (if (not idxtime)
                (index-one (gather-item-data item))
                (if (> (:mtime item) idxtime)
                    (index-one (gather-item-data item))
                    (setv skipped-count (inc skipped-count)))))
        (.info log (% "exiting filesystem walker: %d indexed, %d skipped" (, item-count skipped-count)))))


(defclass IndexingHandler [FileSystemEventHandler]
    ; handle file notifications
    [[--init--
        (fn [self]
            (.debug log "preparing to listen for filesystem events"))]

     [do-update
        (fn [self path]
            (.info log (% "updating %s" path))
            (index-one (gather-item-data
                        {:path  (slice path (+ 1 (len *store-path*)))
                         :mtime (int (time))})))]

     [do-delete
        (fn [self path]
            (.debug log (% "deleting %s" path))
            (delete-wiki-page (slice path (+ 1 (len *store-path*)))))]

     [on-created
        (fn [self event]
            (.debug log (% "creation of %s" event))
            (let [[filename (basename (. event src-path))]
                  [path     (dirname  (. event src-path))]]
                (if (in filename *base-filenames*)
                    (.do-update self path))))]

     [on-deleted
        (fn [self event]
            (.debug log (% "deletion of %s" event))
            (let [[filename (basename (. event src-path))]
                  [path     (dirname  (. event src-path))]]
                (if (in filename *base-filenames*)
                    (.do-delete self path))))]

     [on-modified
        (fn [self event]
            (.debug log (% "modification of %s" event))
            (let [[filename (basename (. event src-path))]
                  [path     (dirname  (. event src-path))]]
                (if (in filename *base-filenames*)
                    (.do-update self path))))]

     [on-moved
        (fn [self event]
            (.debug log (% "renaming of %s" event))
            (let [[srcfile (basename (. event src-path))]
                  [srcpath (dirname  (. event src-path))]
                  [dstfile (basename (. event dest-path))]
                  [dstpath (dirname  (. event dest-path))]]
                (if (in srcfile *base-filenames*)
                    (.do-delete self srcpath))
                (if (in dstfile *base-filenames*)
                    (.do-update self dstpath))))]])


(defn observer [path]
    ; file change observer setup
    (let [[observer (Observer)]
          [handler  (IndexingHandler)]]
        (.debug log (% "Preparing to watch %s" path))
        (apply .schedule [observer handler path] {"recursive" true})
        (.start observer)
        (try
            (while true
                (sleep 1))
            (catch [e KeyboardInterrupt]
                (.stop observer)))
        (.join observer)))


(defn fast-start [n]
    ; TODO: fast start indexing by peeking at the past 3 months 
    (let [[when (.now datetime)] [delta (apply timedelta [] {"weeks" -4})]]
        (for [step (range 0 4)]
           (yield (.strftime (+ when (* step delta)) "%Y/%m")))))


(defmain [&rest args]
    (let [[p        (Profile)]
          [app-name (.get environ "NEW_RELIC_APP_NAME" "Sushy")]]
        (setv (get environ "NEW_RELIC_APP_NAME") (+ app-name " - Indexer")) 
        (.initialize agent)
        (if *profiler*
            (.enable p))
        (init-db)
        ; close database connection to remove contention
        (.close db)
        (setv start-time (time))
        
        (filesystem-walk *store-path*)
        (.info log "Indexing done in %fs" (- (time) start-time))
        (if *profiler*
            (do
                (.disable p)
                (.info log "dumping stats")
                (.dump_stats (Stats p) "indexer.pstats")))
        (if (in "watch" args)
            (do
                (.info log "Starting watcher...")
                (observer *store-path*)))))
