import NIO

public final class QueryBuilder<Model>
    where Model: FluentKit.Model
{
    public var query: DatabaseQuery

    public let database: Database
    internal var includeDeleted: Bool
    internal var joinedModels: [JoinedModel]
    public var eagerLoaders: [AnyEagerLoader]

    struct JoinedModel {
        let model: AnyModel
        let alias: String?
    }
    
    public init(database: Database) {
        self.database = database
        self.query = .init(schema: Model.schema, idKey: Model.key(for: \._$id))
        self.eagerLoaders = []
        self.includeDeleted = false
        self.joinedModels = []
    }

    private init(
        query: DatabaseQuery,
        database: Database,
        eagerLoaders: [AnyEagerLoader],
        includeDeleted: Bool,
        joinedModels: [JoinedModel]
    ) {
        self.query = query
        self.database = database
        self.eagerLoaders = eagerLoaders
        self.includeDeleted = includeDeleted
        self.joinedModels = joinedModels
    }

    public func copy() -> QueryBuilder<Model> {
        .init(
            query: self.query,
            database: self.database,
            eagerLoaders: self.eagerLoaders,
            includeDeleted: self.includeDeleted,
            joinedModels: self.joinedModels
        )
    }

    // MARK: Soft Delete

    public func withDeleted() -> Self {
        self.includeDeleted = true
        return self
    }
    
    // MARK: Actions
    
    public func create() -> EventLoopFuture<Void> {
        self.query.action = .create
        return self.run()
    }
    
    public func update() -> EventLoopFuture<Void> {
        self.query.action = .update
        return self.run()
    }
    
    public func delete() -> EventLoopFuture<Void> {
        self.query.action = .delete
        return self.run()
    }

    // MARK: Limit

    public func limit(_ count: Int) -> Self {
        self.query.limits.append(.count(count))
        return self
    }

    // MARK: Offset

    public func offset(_ count: Int) -> Self {
        self.query.offsets.append(.count(count))
        return self
    }

    // MARK: Unqiue

    public func unique() -> Self {
        self.query.isUnique = true
        return self
    }
    
    // MARK: Fetch
    
    public func chunk(max: Int, closure: @escaping ([Result<Model, Error>]) -> ()) -> EventLoopFuture<Void> {
        var partial: [Result<Model, Error>] = []
        partial.reserveCapacity(max)
        return self.all { row in
            partial.append(row)
            if partial.count >= max {
                closure(partial)
                partial = []
            }
        }.flatMapThrowing { 
            // any stragglers
            if !partial.isEmpty {
                closure(partial)
                partial = []
            }
        }
    }
    
    public func first() -> EventLoopFuture<Model?> {
        return self.limit(1)
            .all()
            .map { $0.first }
    }

    public func all<Field>(_ key: KeyPath<Model, Field>) -> EventLoopFuture<[Field.Value]>
        where Field: FieldRepresentable,
            Field.Model == Model
    {
        let copy = self.copy()
        let fieldKey = Model.key(for: key)
        copy.query.fields = [.field(path: [fieldKey], schema: Model.schema, alias: nil)]
        return copy.all().map {
            $0.map {
                $0[keyPath: key].field.wrappedValue
            }
        }
    }

    public func all<Joined, Field>(
        _ joined: Joined.Type,
        _ key: KeyPath<Joined, Field>
    ) -> EventLoopFuture<[Field.Value]>
        where Field: FieldRepresentable,
            Field.Model == Joined
    {
        let copy = self.copy()
        let fieldKey = Joined.key(for: key)
        copy.query.fields = [.field(path: [fieldKey], schema: Model.schema, alias: nil)]
        return copy.all().flatMapThrowing {
            try $0.map {
                try $0.joined(Joined.self)[keyPath: key].field.wrappedValue
            }
        }
    }

    public func all() -> EventLoopFuture<[Model]> {
        var models: [Result<Model, Error>] = []
        return self.all { model in
            models.append(model)
        }.flatMapThrowing {
            return try models
                .map { try $0.get() }
        }
    }

    public func run() -> EventLoopFuture<Void> {
        return self.run { _ in }
    }

    public func all(_ onOutput: @escaping (Result<Model, Error>) -> ()) -> EventLoopFuture<Void> {
        var all: [Model] = []

        let done = self.run { output in
            onOutput(.init(catching: {
                let model = Model()
                try model.output(from: output)
                all.append(model)
                return model
            }))
        }

        // if eager loads exist, run them, and update models
        if !self.eagerLoaders.isEmpty {
            return done.flatMap {
                // don't run eager loads if result set was empty
                guard !all.isEmpty else {
                    return self.database.eventLoop.makeSucceededFuture(())
                }
                // run eager loads
                return .andAllSync(self.eagerLoaders.map { eagerLoad in
                    { eagerLoad.anyRun(models: all, on: self.database) }
                }, on: self.database.eventLoop)
            }
        } else {
            return done
        }
    }

    internal func action(_ action: DatabaseQuery.Action) -> Self {
        self.query.action = action
        return self
    }


    func run(_ onOutput: @escaping (DatabaseOutput) -> ()) -> EventLoopFuture<Void> {
        // make a copy of this query before mutating it
        // so that run can be called multiple times
        var query = self.query

        if query.fields.isEmpty {
            // default fields
            query.fields = Model().fields.map { (_, field) in
                return .field(
                    path: [field.key],
                    schema: Model.schema,
                    alias: nil
                )
            }
            for joined in self.joinedModels {
                query.fields += joined.model.fields.map { (_, field) in
                    return .field(
                        path: [field.key],
                        schema: joined.alias ?? type(of: joined.model).schema,
                        alias: (joined.alias ?? type(of: joined.model).schema) + "_" + field.key
                    )
                }
            }
        }
        
        // check if model is soft-deletable and should be excluded
        if !self.includeDeleted {
            Model().excludeDeleted(from: &query)
            self.joinedModels
                .forEach { $0.model.excludeDeleted(from: &query) }
        }
        
        self.database.logger.info("\(self.query)")

        let done = self.database.execute(query: query) { row in
            assert(self.database.eventLoop.inEventLoop,
                   "database driver output was not on eventloop")
            onOutput(row.output(for: self.database))
        }
        
        done.whenComplete { _ in
            assert(self.database.eventLoop.inEventLoop,
                   "database driver output was not on eventloop")
        }
        
        return done
    }
}
