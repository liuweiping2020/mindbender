angular.module "mindbender.search", [
    'elasticsearch'
    'json-tree'
    'ngSanitize'
    'mindbender.auth'
]

.config ($routeProvider) ->
    $routeProvider.when "/search/:index*?",
        brand: "Evidently LE", brandIcon: "search"
        title: 'Search {{
                q ? "for [" + q + "] " : (s ? "for [" + s + "] " : "everything ")}}{{
                t ? "in " + t + " " : ""}}{{
                s ? (q ? "from sources matching [" + s + "] " : "") : ""}}{{
                index ? "(" + index + ") " : ""
            }}- DeepDive'
        templateUrl: "search/search.html"
        controller: "SearchResultCtrl"
        reloadOnSearch: no
    $routeProvider.when "/view/:index/:type",
        brand: "Evidently LE", brandIcon: "search"
        title: """{{type}}( {{id}} ) in {{index}} - DeepDive"""
        templateUrl: "search/view.html"
        controller: "SearchViewCtrl"
    $routeProvider.when "/search",
        redirectTo: "/search/"

## for searching extraction/source data
.controller "SearchResultCtrl", ($scope, $routeParams, $location, DeepDiveSearch, $modal) ->
    $scope.search = DeepDiveSearch.init $routeParams.index
    $scope.openModal = (options) ->
        $modal.open _.extend {
            scope: $scope
        }, options

    # make sure we show search results at first visit (when no parameters are there yet)
    if (_.size $location.search()) == 0
        do $scope.search.doSearch

.directive "deepdiveSearchBar", ->
    scope:
        search: "=for"
    templateUrl: "search/searchbar.html"
    controller: ($scope, $routeParams, $location, DeepDiveSearch) ->
        $scope.search ?= DeepDiveSearch.init $routeParams.index
        if $location.path() is "/search/"
            # detect changes to URL
            do doSearchIfNeeded = ->
                DeepDiveSearch.doSearch yes if DeepDiveSearch.importParams $location.search()
            $scope.$on "$routeUpdate", doSearchIfNeeded
            # reflect search parameters to the location on the URL
            $scope.$watch (-> DeepDiveSearch.query), ->
                search = $location.search()
                $location.search k, v for k, v of DeepDiveSearch.params when search.k isnt v
        else
            # switch to /search/
            $scope.$watch (-> DeepDiveSearch.queryRunning), (newQuery, oldQuery) ->
                return unless oldQuery?  # don't mess $location upon load
                $location.search DeepDiveSearch.params
                $location.path "/search/"


.directive "mydatepicker", ->
    restrict: 'A'
    replace: true
    link: ($scope, $element) ->
        $element.bootstrapDP({
            format: "yyyy-mm-dd",
            immediateUpdates: true,
            orientation: "bottom auto"
        })


.directive "queryDossierPicker", ->
    restrict: 'A'
    replace: true
    scope:
        query: "=for"
    link: ($scope, $element) ->
        query = $scope.query
        $.getJSON '/api/dossier/by_query/', {query_string: query}, (options) ->
            options_names = _.pluck options, 'name'
            window.setupMySelectPicker $element, options, (vals) ->
                vals = vals || []
                $.ajax({
                    type: "POST",
                    url: "/api/dossier/by_query/",
                    processData: false,
                    contentType: 'application/json',
                    data: JSON.stringify
                        query_string: query
                        selected_dossier_names: vals
                        unselected_dossier_names: _.difference(options_names, vals)
                    success: ->
                        console.log '/dossier/by_query/:', query, vals
                })


.directive "globalDossierPicker", ->
    restrict: 'A'
    replace: true
    scope:
        search: "=for"
    link: ($scope, $element) ->
        $.getJSON '/api/dossier/', (dossier_names) ->
            _.each dossier_names, (name) ->
                $element.append($('<option/>', {
                    value: name,
                    text: name
                }))
            picker = $element.selectpicker()
            $element.on 'change', ->
                $scope.search.active_dossier = picker.val()
                $scope.$apply()


.directive "dossierQueryPicker", ->
    restrict: 'A'
    replace: true
    scope:
        search: "=for"
    link: ($scope, $element) ->
        $scope.$watch 'search.active_dossier', (dossier_name) ->
            if not dossier_name
                $element.empty()
                $element.prop('disabled', true)
                $element.selectpicker('refresh')
                return
            $.getJSON '/api/dossier/by_dossier/', {dossier_name: dossier_name}, (items) ->
                $element.empty()
                $element.prop('disabled', false)
                _.each items, (item) ->
                    ts = new Date(item.ts_created)
                    date = (ts.getMonth() + 1) + '/' + ts.getDate()
                    time = ts.getHours() + ':' + ts.getMinutes()
                    datetime = date + ' ' + time
                    item_html = item.query_string + ' <em class="small muted">' + item.user_name +
                        ' - ' + datetime +  '</em>'
                    $element.append($('<option/>', {
                        value: item.query_string,
                        text: item.query_string
                    }).data('content', item_html))
                picker = $element.selectpicker('refresh')
                $element.on 'change', ->
                    $scope.search.params.s = picker.val()
                    $scope.search.doSearch()


## for viewing individual extraction/source data
.controller "SearchViewCtrl", ($scope, $routeParams, $location, DeepDiveSearch) ->
    $scope.search = DeepDiveSearch.init $routeParams.indexs
    _.extend $scope, $routeParams
    searchParams = $location.search()
    $scope.id = searchParams.id
    $scope.routing = searchParams.parent
    $scope.data =
        _index: $scope.index
        _type:  $scope.type
        _id:    $scope.id


.directive "deepdiveVisualizedData", (DeepDiveSearch, $q, $timeout) ->
    scope:
        data: "=deepdiveVisualizedData"
        searchResult: "="
        routing: "="
    template: """
        <span ng-include="'search/template/' + data._type + '.html'" onload="finishLoadingCustomTemplate()"></span>
        <span class="alert alert-danger" ng-if="error">{{error}}</span>
        """
    link: ($scope, $element) ->
        $scope.finishLoadingCustomTemplate = () ->
            if $scope.searchResult?
                $element.find(".panel-body").append(
                    TextWithAnnotations.create($scope.searchResult))
            $timeout () ->
                $element.find('[data-toggle=tooltip]').tooltip()

            return false

        $scope.search = DeepDiveSearch.init()
        $scope.isArray = angular.isArray
        showError = (err) ->
            msg = err?.message ? err
            console.error msg
            # TODO display this in template
            $scope.error = msg
        unless $scope.data._type? and ($scope.data._source? or $scope.data._id?)
            return showError "_type with _id or _type with _source must be given to deepdive-visualized-data"
        fetchParentIfNeeded = (data) -> $q (resolve, reject) ->
            if $scope.searchResult?
                # no need to fetch parents ourselves
                resolve data
            else
                DeepDiveSearch.fetchSourcesAsParents [data]
                .then ([data]) -> resolve data
                , reject
        initScope = (data) ->
            switch kind = DeepDiveSearch.types?[data._type]?.kind
                when "extraction"
                    $scope.extractionDoc = data
                    $scope.extraction    = data._source
                    fetchParentIfNeeded data
                    unwatch = $scope.$watch (-> data.parent), (source) ->
                        $scope.sourceDoc = source
                        $scope.source    = source?._source
                        do unwatch if source?
                    , showError
                when "source"
                    $scope.extractionDoc = null
                    $scope.extraction    = null
                    $scope.sourceDoc = data
                    $scope.source    = data._source
                else
                    console.error "#{kind}: Unrecognized kind for type #{data._type}"

        if $scope.data?._source?
            initScope $scope.data
        else
            DeepDiveSearch.fetchWithSource {
                    index: $scope.data._index
                    type: $scope.data._type
                    id: $scope.data._id
                    routing: $scope.routing
                }
            .then (data) ->
                _.extend $scope.data, data
                initScope data
            , showError


.directive "showRawData", ->
    restrict: "A"
    scope:
        data: "=showRawData"
        level: "@"
    template: ($element, $attrs) ->
        if +$attrs.level > 0
            """<json-tree edit-level="readonly" json="data" collapsed-level="{{level}}">"""
        else
            """
            <span ng-hide="showJsonTree"><tt>{<span ng-click="showJsonTree = 1" style="cursor:pointer;">...</span>}</tt></span>
            <json-tree ng-if="showJsonTree" edit-level="readonly" json="data" collapsed-level="2"></json-tree>
            """


# elasticsearch client as an Angular service
.service "elasticsearch", (esFactory) ->
    BASEURL = location.href.substring(0, location.href.length - location.hash.length)
    elasticsearch = esFactory {
        host: "#{BASEURL}api/elasticsearch"
    }
    # do a ping
    elasticsearch.ping {
        requestTimeout: 30000
    }, (err) ->
        console.error "elasticsearch cluster is down", err if err
    # return the instance
    elasticsearch

.service "DeepDiveSearch", (elasticsearch, $http, $q) ->
    MULTIKEY_SEPARATOR = "@"
    class DeepDiveSearch
        constructor: (@elasticsearchIndexName = "_all") ->
            @query = @results = @error = null
            @paramsDefault =
                q: null # query string
                s: null # query string for source
                t: 'everything' # type to search
                n: 10   # number of items in a page
                p: 1    # page number (starts from 1)
            @params = _.extend {}, @paramsDefault
            @types = null
            @indexes = null
            @elastic = elasticsearch
            @collapsed_facets = {}
            @active_dossier = null

            @initialized = $q.all [
                # load the search schema
                $http.get "/api/search/schema.json"
                    .success (data) =>
                        @types = data
                    .error (err) =>
                        console.error err.message
            ,
                # find out what types are in the index
                elasticsearch.indices.get
                    index: @elasticsearchIndexName
                .then (data) =>
                    @indexes = data
                , (err) =>
                    @indexes = null
                    @error = err
                    console.error err.message
            ]

        init: (@elasticsearchIndexName = "_all") =>
            @

        toggleFacetCollpase: (field) =>
            if field of @collapsed_facets
                delete @collapsed_facets[field]
            else
                @collapsed_facets[field] = true

        doSearch: (isContinuing = no) => @initialized.then =>
            @params.p = 1 unless isContinuing
            fieldsSearchable = @getFieldsFor "searchable", @params.t
            @error = null
            # query_string query
            if (st = (@getSourceFor @params.t)?.type)?
                # extraction type
                sq = @params.s
                qs = @params.q
            else
                # source type
                sq = null
                qs = @params.s

            qs = qs || ''
            if window.visualSearch
                window.visualSearch.searchBox.value(qs)
            q =
                if qs?.length > 0
                    # Take care of quotations added by VisualSearch
                    qs_for_es = qs.replace(/["']\[/g, '[').replace(/\]["']/g, ']')
                    query_string:
                        default_field: "content"
                        default_operator: "AND"
                        query: qs_for_es
            # also search source when possible
            # TODO highlight what's found here?
            if st? and sq?.length > 0
                q = bool:
                    should: [
                        q
                      , has_parent:
                            parent_type: st
                            query:
                                query_string:
                                    default_field: "content"
                                    default_operator: "AND"
                                    query: sq
                    ]
                    minimum_should_match: 2
            # forumate aggregations
            aggs = {}
            if @indexes?
                for navigable in @getFieldsFor ["navigable", "searchableXXXXXX"], @params.t
                    aggs[navigable] =
                        switch @getFieldType navigable
                            when "boolean"
                                terms:
                                    field: navigable
                            when "stringXXXXXX"
                                # significant_terms buckets are empty if query is empty;
                                # terms buckets are not empty in that case.
                                # we want to show facets even for initial page with empty query.
                                if qs?.length > 0
                                    significant_terms:
                                        field: navigable
                                        min_doc_count: 1
                                else
                                    terms:
                                        field: navigable
                            when "long"
                                # TODO range? with automatic rnages
                                # TODO extended_stats?
                                stats:
                                    field: navigable
                            else # TODO any better default for unknown types?
                                terms:
                                    field: navigable
                    aggs[navigable + '__count'] =
                        value_count:
                            field: navigable
            query =
                index: @elasticsearchIndexName
                type: @params.t
                body:
                    # elasticsearch Query DSL (See: https://www.elastic.co/guide/en/elasticsearch/client/javascript-api/current/quick-start.html#_elasticsearch_query_dsl)
                    size: @params.n
                    from: (@params.p - 1) * @params.n
                    query: q
                    # TODO support filters
                    aggs: aggs
                    highlight:
                        tags_schema: "styled"
                        fields: _.object ([f,{require_field_match: true}] for f in fieldsSearchable)
            @queryRunning = query
            @querystringRunning = qs
            elasticsearch.search query
            .then (data) =>
                @error = null
                @queryRunning = null
                @querystringRunning = null
                @query = query
                @query._query_string = qs
                @query._source_type = st
                @query._source_query_string = sq
                @results = data
                @fetchSourcesAsParents @results.hits.hits
                facets = []
                best_facets = ['domain_type', 'flags', 'domain', 'locations', 'phones', 'post_date']
                range_facets = ['ages', 'post_date', 'phones', 'ages']
                date_facets = ['post_date']
                for f in best_facets
                    if f of data.aggregations
                        facet = data.aggregations[f]
                        facet.field = f
                        facet.count = data.aggregations[f + '__count'].value
                        facet.is_range = (f in range_facets)
                        facet.is_date = (f in date_facets)
                        if f of @collapsed_facets
                            facet.collapsed = true
                        facets.push facet
                for k, v of data.aggregations
                    if k not in best_facets and k + '__count' of data.aggregations
                        facet = data.aggregations[k]
                        facet.field = k
                        facet.count = data.aggregations[k + '__count'].value
                        facet.is_range = (k in range_facets)
                        facet.is_date = (k in date_facets)
                        if k of @collapsed_facets
                            facet.collapsed = true
                        facets.push facet
                @results.facets = facets

                idx = query.body.from + 1
                for hit in data.hits.hits
                    hit.idx = idx++

            , (err) =>
                @error = err
                console.error err.message
                @queryRunning = null

        fetchSourcesAsParents: (docs) => $q (resolve, reject) =>
            # TODO cache sources and invalidate upon ever non-continuing search?
            # find out what source docs we need fetch for current search results
            docRefs = []; docsByMgetOrder = []
            for doc in docs when (parentRef = @getSourceFor doc._type)? and not doc.parent?
                docsByMgetOrder.push doc
                docRefs.push
                    _index: doc._index
                    _type: parentRef.type
                    _id: (doc._source[f] for f in parentRef.fields).join MULTIKEY_SEPARATOR
            return resolve docs unless docRefs.length > 0
            # fetch sources
            elasticsearch.mget { body: { docs: docRefs } }
            .then (data) =>
                # update the source (parent) for every extractions
                for sourceDoc,i in data.docs
                    docsByMgetOrder[i].parent = sourceDoc
                resolve docs
            , reject

        fetchWithSource: (docRef) => $q (resolve, reject) =>
            docRef.index ?= @elasticsearchIndexName
            # TODO lifted version of this with mget
            elasticsearch.get docRef
            .then (data) =>
                @fetchSourcesAsParents [data]
                .then => resolve data
                , reject
            , reject

        doNavigate: (field, value, newSearch = false) =>
            qsExtra =
                if value?
                    if field in @getFieldsFor "navigable"
                        # use field-specific search for navigable fields
                        # VisualSearch may have added the quotes already
                        if value.indexOf("'") == 0 or value.indexOf('"') == 0
                            "#{field}: #{value}"
                        else
                            "#{field}: \"#{value}\""
                    else if field in @getFieldsFor "searchable"
                        # just add extra keyword to the search
                        value
                else if field?
                    # filtering down null has a special query_string syntax
                    "_missing_:#{field}"
                else
                    ""
            qsExtra = qsExtra || ''
            # TODO check if qsExtra is already there in @params.q
            qs = if (@getSourceFor @params.t)? then "q" else "s"
            @params[qs] =
                if newSearch or not @params[qs]
                    qsExtra
                else if qsExtra and @params[qs].indexOf(qsExtra) == -1
                    "#{@params[qs]} #{qsExtra}"
                else
                    @params[qs]
            @doSearch no

        splitQueryString: (query_string) =>
            # TODO be sensitive to "phrase with spaces"
            query_string.split /\s+/

        getSourceFor: (type) =>
            @types?[type]?.source

        getFieldsFor: (what, type = @params.t) =>
            if what instanceof Array
                # union if multiple purposes
                _.union (@getFieldsFor w, type for w in what)...
            else
                # get all fields for something for the type or all types
                if type?
                    @types?[type]?[what] ? []
                else
                    _.union (s[what] for t,s of @types)...

        getFieldType: (path) =>
            for idxName,{mappings} of @indexes ? {}
                for typeName,mapping of mappings
                    # traverse down the path
                    pathSoFar = ""
                    for field in path.split "."
                        if pathSoFar?
                            pathSoFar += ".#{field}"
                        else
                            pathSoFar = field
                        if mapping.properties?[field]?
                            mapping = mapping.properties[field]
                        else
                            #console.debug "#{pathSoFar} not defined in mappings for [#{idxName}]/[#{typeName}]"
                            mapping = null
                            break
                    continue unless mapping?.type?
                    return mapping.type
            console.error "#{path} not defined in any mappings"
            null

        countTotalDocCountOfBuckets: (aggs) ->
            return aggs._total_doc_count if aggs?._total_doc_count? # try to hit cache
            total = 0
            if aggs?.buckets?
                total += bucket.doc_count for bucket in aggs.buckets
                aggs._total_doc_count = total # cache sum
            total

        importParams: (params) =>
            changed = no
            for k,v of @params when (params[k] ? @paramsDefault[k]) isnt v
                @params[k] = params[k] ? @paramsDefault[k]
                changed = yes
            changed

    new DeepDiveSearch

# a handy filter for generating safe id strings for HTML
.filter "safeId", () ->
    (text) ->
        text?.replace /[^A-Za-z0-9_-]/g, "_"
