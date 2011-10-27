require 'helper'

class TestConnection < Test::Unit::TestCase
  include JDBCHelperTestHelper

  def setup
  end

  def teardown
    conn.update "drop table #{TEST_TABLE}" rescue nil
    conn.update "drop procedure #{TEST_PROCEDURE}" rescue nil
  end

  TEST_TABLE = 'tmp_jdbc_helper_test'
  TEST_PROCEDURE = 'tmp_jdbc_helper_test_proc'

  def get_one_two
    "
    select 1 one, 'two' two from dual
    union all
    select 1 one, 'two' two from dual
    "
  end

  def check_one_two(rec)
    assert_equal 2, rec.length

    assert_equal 1, rec.one
    assert_equal 1, rec[0]
    assert_equal 1, rec['one']
    assert_equal 1, rec[:one]
    assert_equal [1], rec[0...1]
    assert_equal [1], rec[0, 1]

    assert_equal 'two', rec.two
    assert_equal 'two', rec[1]
    assert_equal 'two', rec['two']
    assert_equal ['two'], rec[1..-1]
    assert_equal ['two'], rec[1, 1]

    assert_equal [1, 'two'], rec[0..1]
    assert_equal [1, 'two'], rec[0..-1]
    assert_equal [1, 'two'], rec[0, 2]

    # FIXME: Exponent field
    assert rec.join('--') =~ /--two$/

    assert_raise(NoMethodError) { rec.three }
    assert_raise(NameError) { rec['three'] }
    assert_raise(NameError) { rec[:three] }
    assert_raise(RangeError) { rec[3] }
  end

  def reset_test_table conn
    conn.update "drop table #{TEST_TABLE}" rescue nil
    cnt = conn.update "
      create table #{TEST_TABLE} (
        a int primary key,
        b varchar(100)
      )"
    assert_equal 0, cnt
  end

  def reset_test_table_ts conn
    conn.update "drop table #{TEST_TABLE}" rescue nil
    cnt = conn.update "
      create table #{TEST_TABLE} (
        a timestamp,
        b date
        #{", c time" if @type == :mysql}
      )"
    assert_equal 0, cnt
  end

  # ---------------------------------------------------------------
  
  def test_invalid_driver
    assert_raise(NameError) {
      JDBCHelper::Connection.new(:driver => 'xxx', :url => 'localhost')
    }
  end

  def test_connect_clone_and_close
    config.each do | db, conn_info_org |
      4.times do | i |
        conn_info = conn_info_org.reject { |k,v| k == 'database' }

        # With or without timeout parameter
        conn_info['timeout'] = 60 if i % 2 == 1

        # Can connect with hash with symbol keys?
        conn_info.keys.each do | str_key |
          conn_info[str_key.to_sym] = conn_info.delete str_key
        end if i % 2 == 0

        # Integers will be converted to String
        #conn_info['defaultRowPrefetch'] = 1000

        conn_info.freeze # Non-modifiable!
        conn = JDBCHelper::Connection.new(conn_info)
        assert_equal(conn.closed?, false)
        assert_equal(conn.driver, conn_info[:driver] || conn_info['driver'])
        assert_equal(conn.url, conn_info[:url] || conn_info['url'])

        conn.fetch_size = 100
        assert_equal 100, conn.fetch_size

        conn.close
        assert_equal(conn.closed?, true)
        [ :query, :update, :add_batch, :prepare ].each do | met |
          assert_raise(RuntimeError) { conn.send met, "A" }
        end
        [ :execute_batch, :clear_batch ].each do | met |
          assert_raise(RuntimeError) { conn.send met }
        end

        new_conn = conn.clone
        assert new_conn.java_obj != conn.java_obj
        assert new_conn.closed? == false
        assert_equal 100, new_conn.fetch_size
        new_conn.close

        # initialize with execution block
        conn = JDBCHelper::Connection.new(conn_info) do | c |
          c2 = c.clone
          assert c2.java_obj != c.java_obj

          c.query('select 1 from dual')
          c2.query('select 1 from dual')
          assert_equal c.closed?, false

          c2.close
          assert c2.closed?
        end
        assert conn.closed?
      end
    end
  end

  def test_fetch_size
    each_connection do | conn |
      assert_nil conn.fetch_size
      conn.fetch_size = 10
      assert_equal 10, conn.fetch_size
      conn.set_fetch_size 20
      assert_equal 20, conn.fetch_size

      # No way to confirm whether if this is really working as it's supposed to be.

      conn.query('select 1 from dual') do |r1|
        assert_equal 20, conn.fetch_size
        conn.query('select 1 from dual') do |r2|
          assert_equal 20, conn.fetch_size
          conn.query('select 1 from dual') do |r3|
            assert_equal 20, conn.fetch_size
            conn.set_fetch_size 30
            assert_equal 30, conn.fetch_size
          end
          assert_equal 30, conn.fetch_size
        end
        assert_equal 30, conn.fetch_size
      end
      assert_equal 30, conn.fetch_size
    end
  end

  def test_query_enumerate
    each_connection do | conn |
      # Query without a block => Array
      query_result = conn.query get_one_two
      assert query_result.is_a? Array
      assert_equal 2, query_result.length
      check_one_two(query_result.first)
      assert_equal query_result.first, query_result.last

      # Query with a block
      count = 0
      conn.query(get_one_two) do | row |
        check_one_two row
        count += 1
      end
      assert_equal 2, count

      # Enumerate
      enum = conn.enumerate(get_one_two)
      assert enum.is_a? Enumerable
      assert enum.closed? == false
      a = enum.to_a
      assert_equal 2, a.length
      check_one_two a.first
      assert enum.closed? == true
    end
  end

  def test_enumerate_errors
    each_connection do |conn|
      # On error, Statement object must be returned to the StatementPool
      (JDBCHelper::Constants::MAX_STATEMENT_NESTING_LEVEL * 2).times do |i|
        conn.enumerate('xxx') rescue nil
      end
      assert_equal 'OK', conn.query("select 'OK' from dual")[0][0]
    end
  end

  def test_deep_nesting
    nest = lambda { |str, lev|
      if lev > 0
        "conn.query('select 1 from dual') do |r#{lev}|
           #{nest.call str, lev - 1}
         end"
      else
        str
      end
    }
    (1..(JDBCHelper::Constants::MAX_STATEMENT_NESTING_LEVEL + 1)).each do |level|
      each_connection do |conn|
        str = nest.call('assert true', level)
        if level > JDBCHelper::Constants::MAX_STATEMENT_NESTING_LEVEL
          assert_raise(RuntimeError) { eval str }
        else
          eval str
        end
      end
    end
  end

  def test_update_batch
    each_connection do | conn |
      reset_test_table conn
      count = 100

      iq = lambda do | i |
        "insert into #{TEST_TABLE} values (#{i}, 'A')"
      end
      ins1 = conn.prepare "insert into #{TEST_TABLE} values (? + #{count}, ?)"
      ins2 = conn.prepare "insert into #{TEST_TABLE} values (? + #{count * 2}, ?)"

      # update
      assert_equal 1, conn.update(iq.call 0)
      assert_equal 1, conn.prev_stat.success_count

      # add_batch execute_batch
      reset_test_table conn

      count.times do | p |
        conn.add_batch iq.call(p)
        ins1.add_batch p, 'B'.to_java
        ins2.add_batch p, 'C'
      end
      conn.execute_batch
      assert_equal count * 3, conn.table(TEST_TABLE).count
      assert conn.table(TEST_TABLE).where("a >= #{count}", "a < #{count * 2}").map(&:b).all? { |e| e == 'B' }
      assert conn.table(TEST_TABLE).where("a >= #{count * 2}").map(&:b).all? { |e| e == 'C' }

      # add_batch clear_batch
      reset_test_table conn

      count.times do | p |
        conn.add_batch iq.call(p)
        ins1.add_batch p, 'B'.to_java
        ins2.add_batch p, 'C'
      end
      conn.clear_batch
      # Already cleared, no effect
      ins1.execute_batch
      ins2.execute_batch
      assert_equal 0, conn.table(TEST_TABLE).count
    end
  end

  def test_prepared_query_enumerate
    each_connection do | conn |
      2.times do |iter|
        sel = conn.prepare get_one_two
        assert sel.closed? == false
        assert_equal conn.prepared_statements.first, sel

        # Fetch size
        if iter == 0
          assert_nil conn.fetch_size
          assert_nil sel.fetch_size
        end
        conn.fetch_size = 100
        sel.fetch_size  = 10
        assert_equal 100, conn.fetch_size
        assert_equal 10,  sel.fetch_size
        sel.set_fetch_size 20
        assert_equal 100, conn.fetch_size
        assert_equal 20,  sel.fetch_size

        # Query without a block => Array
        query_result = sel.query
        assert query_result.is_a? Array
        assert_equal 2, query_result.length
        check_one_two(query_result.first)

        # Query with a block
        count = 0
        sel.query do | row |
          check_one_two row
          count += 1
        end
        assert_equal 2, count

        # Enumerate
        enum = sel.enumerate
        assert enum.is_a? Enumerable
        assert enum.closed? == false
        a = enum.to_a
        assert_equal 2, a.length
        check_one_two a.first
        assert enum.closed? == true

        if iter == 0
          sel.close
        else
          sel.java_obj.close
        end

        assert sel.closed?
        [ :query, :update, :add_batch, :execute_batch, :clear_batch ].each do | met |
          assert_raise(RuntimeError) { sel.send met }
        end
      end#times
    end#each_connection
  end

  def test_prepared_update_batch
    each_connection do | conn |
      reset_test_table conn
      ins = conn.prepare "insert into #{TEST_TABLE} values (?, ?)"
      assert_equal 2, ins.parameter_count
      assert_equal conn.prepared_statements.first, ins

      count = 100

      # update
      assert ins.closed? == false
      assert_equal 1, ins.update(0, 'A')
      assert_equal 1, conn.prev_stat.success_count
      ins.close
      assert_equal 0, conn.prepared_statements.length

      # add_batch execute_batch
      2.times do |iter|
        reset_test_table conn
        ins = conn.prepare "insert into #{TEST_TABLE} values (?, ?)"
        assert_equal conn.prepared_statements.first, ins if iter == 0

        count.times do | p |
          ins.add_batch(p + 1, 'A')
        end
        if iter == 0
          ins.execute_batch
        else
          conn.execute_batch
        end
        assert_equal count, conn.table(TEST_TABLE).count
        ins.close
        # 1 for count
        assert_equal 1, conn.prepared_statements.length
      end

      # add_batch clear_batch
      reset_test_table conn
      ins = conn.prepare "insert into #{TEST_TABLE} values (?, ?)"
      assert_equal conn.prepared_statements.last, ins # count is first

      # clear_batch
      2.times do |iter|
        count.times do | p |
          ins.add_batch(p + 1, 'A')
        end
        if iter == 0
          ins.clear_batch
        else
          conn.clear_batch
        end
        assert_equal 0, conn.table(TEST_TABLE).count
      end

      # close closed?
      assert ins.closed? == false
      ins.close
      # 1 for count
      assert_equal 1, conn.prepared_statements.length
      assert ins.closed?
      [ :query, :update, :add_batch, :execute_batch, :clear_batch ].each do | met |
        assert_raise(RuntimeError) { ins.send met }
      end
    end
  end
  
  def test_transaction
    each_connection do | conn |
      reset_test_table conn
      count = 100

      3.times do | i |
        sum = 0
        conn.update "delete from #{TEST_TABLE}"
        conn.transaction do | tx |
          count.times.each_slice(10) do | slice |
            slice.each do | p |
              conn.add_batch("insert into #{TEST_TABLE} values (#{p}, 'xxx')")
              sum += p
            end
            conn.execute_batch
          end
          result = conn.query("select count(*), sum(a) from #{TEST_TABLE}").first

          assert_equal count, result.first
          assert_equal sum, result.last

          case i
          when 0 then tx.rollback
          when 1 then tx.commit
          else
            nil # committed implicitly
          end

          flunk 'This should not be executed' if i < 2
        end

        assert_equal (i == 0 ? 0 : count),
          conn.table(TEST_TABLE).count
      end
    end
  end

  def test_setter_timestamp
    require 'date'
    each_connection do | conn |
      # Java timestamp
      reset_test_table_ts conn
      now = Time.now
      lt = (now.to_f * 1000).to_i
      ts = java.sql.Timestamp.new(lt)
      d = java.sql.Date.new( Time.mktime(Date.today.year, Date.today.month, Date.today.day).to_i * 1000 )
      t = java.sql.Time.new lt

      if @type == :mysql
        conn.prepare("insert into #{TEST_TABLE} (a, b, c) values (?, ?, ?)").update(ts, d, t)
        # MySQL doesn't have subsecond precision
        assert [lt, lt / 1000 * 1000].include?(conn.query("select a from #{TEST_TABLE}")[0][0].getTime)
        # The JDBC spec states that java.sql.Dates have _no_ time component
        # http://bugs.mysql.com/bug.php?id=2876
        assert_equal d.getTime, conn.query("select b from #{TEST_TABLE}")[0][0].getTime

        # http://stackoverflow.com/questions/907170/java-getminutes-and-gethours
        t2 = conn.query("select c from #{TEST_TABLE}")[0][0]
        cal = java.util.Calendar.getInstance
        cal.setTime(t)
        cal2 = java.util.Calendar.getInstance
        cal2.setTime(t2)
        assert_equal now.hour, cal2.get(java.util.Calendar::HOUR_OF_DAY)
        assert_equal now.min, cal2.get(java.util.Calendar::MINUTE)
        assert_equal now.sec, cal2.get(java.util.Calendar::SECOND)
        assert_equal cal.get(java.util.Calendar::HOUR_OF_DAY), cal2.get(java.util.Calendar::HOUR_OF_DAY)
        assert_equal cal.get(java.util.Calendar::MINUTE), cal2.get(java.util.Calendar::MINUTE)
        assert_equal cal.get(java.util.Calendar::SECOND), cal2.get(java.util.Calendar::SECOND)
      end

      # Ruby time
      reset_test_table_ts conn
      ts = Time.now
      conn.prepare("insert into #{TEST_TABLE} (a) values (?)").update(ts)
      got = conn.query("select a from #{TEST_TABLE}")[0][0]
      assert [ts.to_i * 1000, (ts.to_f * 1000).to_i].include?(got.getTime)
    end
  end

  # Conditional testing is bad, but
  # Oracle and MySQL behave differently.
  def test_callable_statement
    each_connection do | conn |
      # Creating test procedure (Defined in JDBCHelperTestHelper)
      create_test_procedure conn, TEST_PROCEDURE

      # Array parameter
      cstmt_ord = conn.prepare_call "{call #{TEST_PROCEDURE}(?, ?, ?, ?, ?, ?, ?)}"
      result = cstmt_ord.call('hello', 10, [100, Fixnum], [Time.now, Time], nil, Float, String)
      assert_instance_of Hash, result
      assert_equal 1000, result[3]
      assert_equal 'hello', result[7]

      # Hash parameter
      cstmt_name = conn.prepare_call(case @type
            when :oracle
              "{call #{TEST_PROCEDURE}(:i1, :i2, :io1, :io2, :n1, :o1, :o2)}"
            else
              "{call #{TEST_PROCEDURE}(?, ?, ?, ?, ?, ?, ?)}"
            end)
      result = cstmt_name.call(
        :i1 => 'hello', :i2 => 10,
        :io1 => [100, Fixnum], 'io2' => [Time.now, Time], 
        :n1 => nil,
        :o1 => Float, 'o2' => String)
      assert_instance_of Hash, result
      assert_equal 1000, result[:io1]
      assert_equal 'hello', result['o2']

      # Invalid parameters
      #assert_raise(NativeException) { cstmt_ord.call 1 }
      assert_raise(ArgumentError)   { cstmt_ord.call({}, {}) }
      assert_raise(NativeException) { cstmt_name.call 1 }
      assert_raise(ArgumentError)   { cstmt_name.call({}, {}) }

      # Close
      [ cstmt_ord, cstmt_name ].each do | cstmt |
        assert_equal false, cstmt.closed?
        cstmt.close
        assert_equal true, cstmt.closed?
        assert_raise(RuntimeError) { cstmt.call }
      end

      # Data truncated for column 'io1' at row 2. WHY?
      # http://www.herongyang.com/JDBC/MySQL-CallableStatement-INOUT-Parameters.html
      if @type != :mysql
        cstmt_ord = conn.prepare_call "{call #{TEST_PROCEDURE}('howdy', ?, ?, ?, ?, ?, ?)}"
        cstmt_name = conn.prepare_call(case @type
            when :oracle
              "{call #{TEST_PROCEDURE}('howdy', :i2, :io1, :io2, :n1, :o1, :o2)}"
            else
              "{call #{TEST_PROCEDURE}('howdy', ?, ?, ?, ?, ?, ?)}"
            end)
        # Hash parameter
        result = cstmt_name.call(
          #:i1 => 'hello',
          :i2 => 10,
          :io1 => [100, Fixnum], 'io2' => [Time.now, Time], 
          :n1 => nil,
          :o1 => Float, 'o2' => String)
        assert_instance_of Hash, result
        assert_equal 1000, result[:io1]
        assert_equal 'howdy', result['o2']

        # Array parameter
        result = cstmt_ord.call(10, [100, Fixnum], [Time.now, Time], nil, Float, String)
        assert_instance_of Hash, result
        assert_equal 1000, result[2]
        assert_equal 'howdy', result[6]

        # Close
        [ cstmt_ord, cstmt_name ].each do | cstmt |
          assert_equal false, cstmt.closed?
          cstmt.close
          assert_equal true, cstmt.closed?
          assert_raise(RuntimeError) { cstmt.call }
        end
      end
    end
  end
end

