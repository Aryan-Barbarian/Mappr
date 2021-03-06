require 'csv'
require 'json'

class Dataset < ActiveRecord::Base
    belongs_to :user
    has_many :columns
    has_many :maps

    after_initialize :after_initialize

    @@full_to_fips = JSON.parse(File.read("#{Rails.root}/app/models/full_to_fips.json"))
    logger.debug "English to FIPS file: #{@english_to_fips}"


    @@fips_to_full = JSON.parse(File.read("#{Rails.root}/app/models/fips_to_full.json"))

    file = File.read("#{Rails.root}/app/models/states_hash.json")
    @@states_hash = JSON.parse(file)

    # Will read through the filestream to make sure it is valid: 
    # * be parseable CSV
    # * contain every column that the dataset is supposed to contain.
    # * have fewer than 500,000 rows
    # It will then write the filestream to the dataset's existing filepath. 
    # It will return TRUE iff successful, FALSE otherwise
    def consume_raw_file(filestream)
        # TODO: Validate file
        if not self.filepath
            self.filepath = self.generate_filepath
        end
        outpath = self.filepath


        File.open(outpath, 'wb') do |f|
            f.write(filestream)
        end

        rows = Array.new
        county_full_col = Column.find_by(dataset_id: self.id, detail_level: "countyfull")
        county_partial_col = Column.find_by(dataset_id: self.id, detail_level: "countypartial")
        state_col = Column.find_by(dataset_id: self.id, detail_level: "state")

        CSV.foreach(outpath, :headers => true) do |row|
            row = row.to_hash
            row["STATE_FIPS_MAPPR"] = self.generate_row_location(row, "STATE", county_full_col, county_partial_col, state_col)
            row["COUNTY_FIPS_MAPPR"] = self.generate_row_location(row, "COUNTY", county_full_col, county_partial_col, state_col)
            rows.push(row)
        end

        CSV.open(outpath, "wb", write_headers: true, headers: rows.first.keys) do |csv|
            rows.each do |h|
                csv << h.values
            end
        end
    end

    def is_fips?(query)
        if not query or query.length != 5
            return false
        end

        return /\A\d+\z/.match(query)
    end

    def generate_filepath
        self.save
        filepath = "#{Rails.root}/datasets/#{self.id}.csv"
        self.filepath = filepath
        self.save
        return filepath
    end

    def destroy_file!
        # File.delete(self.filepath) if File.exist?(self.filepath)
    end

    def after_initialize
        # logger.debug "AFTER INITIALIZE"
        # filepath = self.generate_filepath()
        # logger.debug "Generated filepath: #{filepath}"
        # self.filepath = filepath
    end

    # Takes a string that represents location and returns a 5-digit
    # FIPS code representation of that location, or NULL if unknown
    # Params:
    # location - a string representation of a location of a row. Must conform to one of the known location types.
    # location_type - The way that the given location parameter has been represented. Can have the following types:
    # * state - NJ or New Jersey
    # * statefips - 23 or 23000
    # * countypartial - Bergen
    # * countypartialfips - 234 or 00234
    # * countyfull - Bergen, New Jersey or Bergen, NJ
    # * countyfullfips - 23234
    def convert_to_fips(location)
        # TODO: this doesn't handle cases like "Bergen, 234" where fips and normal are mixed in
        location = location.upcase

        if @@states_hash.has_key?(location)
            location = @@states_hash[location]
        end

        if @@full_to_fips.has_key?(location)
            location = @@full_to_fips[location]
        end

        return location
    end

    def abbrev_to_state(location)
        location = location.upcase
        if @@states_hash.has_key?(location)
            location = @@states_hash[location]
        end
        return location
    end

    def fips_to_state(state_fips)
        full_fips = state_fips.ljust(5, "0")
        if @@fips_to_full.has_key?(location)
            return @@fips_to_full[location]["state"]
        else
            return state_fips
        end
    end

    def state_to_fips(state)
        ans = state
        if self.is_numeric?(ans)
            ans.ljust(5, "0")
        else
            ans = abbrev_to_state(ans).upcase
            ans = convert_to_fips(ans)
            ans = ans.rjust(5, "0")
        end
        return ans
    end

    def fips_to_county(county_fips)
        full_fips = state_fips.rjust(5, "0")
        if @@fips_to_full.has_key?(location) and @@fips_to_full["location"].has_key?("county")
            return @@fips_to_full[location]["county"]
        else
            return state_fips
        end
    end

    def is_numeric?(query)
        return (/\A\d+\z/.match(query))
    end


    # Returns a 5-digit FIPS code that represents this row's location as long as the dataset contains the correct columns.
    # Params:
    # row - a CSV row (a hash where keys are column headers)
    # detail_level - a string that is either "STATE" or "COUNTY" that represents what detail to query locations by.
    def generate_row_location(row, detail_level, county_full_col, county_partial_col, state_col)

        if detail_level == "STATE"

            if county_full_col
                col_name = county_full_col.name
                ans = row[col_name].upcase.strip
                ans = convert_to_fips(ans)
                ans = ans.ljust(5, "0")
                return ans
            elsif state_col
                col_name = state_col.name
                ans = row[col_name].upcase
                ans = state_to_fips(ans)
                ans = ans.ljust(5, "0")
                return ans
            else
                # ERROR??
                return nil
            end
                
        elsif detail_level == "COUNTY"

            if county_full_col
                col_name = county_full_col.name
                ans = row[col_name].upcase
                ans = convert_to_fips(ans)
                ans = ans.rjust(5, "0")
                return ans
            elsif state_col and county_partial_col
                # TODO: might error if null
                state_name = row[state_col.name]
                county_name = row[county_partial_col.name]

                state_name = state_name.upcase
                county_name = county_name.upcase
                
                if self.is_numeric?(state_name) and self.is_numeric?(county_name)
                    state_name = state_name.ljust(5, "0")[0..1]
                    county_name = county_name.rjust(5, "0")[2..5]
                    return state_name + county_name
                elsif self.is_numeric?(county_name)
                    state_name = self.abbrev_to_state(state_name)
                    state_name = self.state_to_fips(state_name).ljust(5, "0")[0..1]
                    county_name = county_name.rjust(5, "0")[2..5]
                    return state_name + county_name
                elsif self.is_numeric?(state_name)
                    state_name = self.fips_to_state(state_name)
                end

                key = "#{county_name}, #{state_name}"
                ans = convert_to_fips(key)
                return ans
            else
                # ERROR
                return nil
            end
        else
            # ERROR
            return nil
        end         
    end

    # Returns a hash containing every single datapoint in this dataset. These should be condensed by some other function.
    # The response format is { 5-digit FIPS code for a location => [list of datapoints belonging to that location]}
    # The format of each datapoint is { display_val: XX, filter_val: YY, weight: ZZ, location: QQ}
    # Params
    # display_val_name - The name of the column to select display values from
    # display_val_name - The name of the column to select filter values from. Can be null.
    # detail_level - The level of location detail to return. Can be "STATE" or "COUNTY".
    def generate_raw_points(display_val_name, filter_val_name, detail_level)

        line_num = 0

        # { 5 digit fips code => [ ... list of points ... ]}
        ans = Hash.new
        
        # TODO: Is this gonna error when there's multiple datasets?
        display_column = Column.find_by(dataset_id: self.id, name: display_val_name)

        display_null_val = display_column[:null_value]
        
        if not filter_val_name.nil?
            filter_column = Column.find_by(dataset_id: self.id, name: filter_val_name)
            filter_null_val = filter_column[:null_value]
        else
            filter_null_val = "-1"
            filter_column = nil
        end

        weight_column = Column.find_by(dataset_id: self.id, column_type: "WEIGHT")
        if weight_column
            weight_column_name = weight_column.name
        else
            weight_column_name = nil
        end

        filepath = self.filepath
        # Iterate through the file raw
        CSV.foreach(filepath, :headers => true) do |row|

            row = row.to_hash
            display_val = row[display_val_name]

            if not filter_val_name.nil?
                filter_val = row[filter_val_name] # TODO: or nil if we don't have a filter
            else
                filter_val = "1"
            end

            if display_val == display_null_val or filter_val == filter_null_val
                next
            end

            if not weight_column_name.nil?
                weight = row[weight_column_name].to_f
            else
                weight = 1
            end
            
            loc = self.get_row_location(row, detail_level)

            if not is_fips?(loc)
                # TODO: ERROR
                logger.error "SHOULD BE FIPS #{loc}"
            end

            if not ans.has_key?(loc)
                ans[loc] = Array.new
            end

            datapoint = {display_val: display_val,
                filter_val: filter_val,
                location: loc,
                weight: weight}

            ans[loc].push(datapoint)
            
            line_num += 1
        end

        ans = {by_location: ans, num_points: line_num}
        return ans
    end


    def get_row_location(row, detail_level)
        ans = nil
        if detail_level == "STATE"
            ans = row["STATE_FIPS_MAPPR"]
        elsif detail_level == "COUNTY"
            ans = row["COUNTY_FIPS_MAPPR"]
        end

        # if ans.nil?
        #     logger.debug("The row gave null value #{row}")
        # end

    end

    # Returns a hash containing a representative set of datapoints from this dataset.
    # The response format is { 5-digit FIPS code for a location => [list of datapoints belonging to that location]}
    # The format of each datapoint is { display_val: XX, filter_val: YY, weight: ZZ}
    # Params
    # num_points_wanted - The maximum number of desired datapoints. This can not be less than the number of unique locations. The number of points returned can be less than this.
    # display_val_name - The name of the column to select display values from
    # display_val_name - The name of the column to select filter values from. Can be null.
    # detail_level - The level of location detail to return. Can be "STATE" or "COUNTY".
    def generate_points(num_points_wanted, display_val_name, filter_val_name, detail_level)
        # TODO: add error checking

        all_points = self.generate_raw_points(display_val_name, filter_val_name, detail_level)[:by_location]
        

        # if all_points[0][:location].nil?
        #     logger.error "DATAPOINT LOCATION SHOULD NOT BE nil : #{all_points[0]}"
        # end

        merged_dups_ans = self.merge_repeats(all_points)
        merged_dups = merged_dups_ans[:by_location]
        num_points = merged_dups_ans[:num_points]

        condense_factor = num_points_wanted * 1.0 / num_points
        condensed_ans = self.condense_by_location(merged_dups, condense_factor)
        condensed_points = condensed_ans[:by_location]

        num_points = condensed_ans[:num_points]

        ans = Array.new

        condensed_points.each do |loc, points|
            points.each do |point|
                ans.push(point)
            end
        end
        logger.debug "FIRST points: #{ans[0]}"
        return ans
    end

    # If two datapoints have the same exact location, display_val, and filter_val, this method merges them into one point.
    # Params
    # by_location - A hash of datapoints. This has the same format as that returned by generate_raw_points.
    def merge_repeats(by_location)
        ans = Hash.new
        num_points = 0

        by_location.each do |loc, points|
            seen = Hash.new

            points.each do |point|
                display_val = point[:display_val]
                filter_val = point[:filter_val]
                weight = point[:weight]

                key = [display_val, filter_val]
                if not seen.has_key?(key)
                    seen[key] = 0
                end
                seen[key] += weight
            end

            ans[loc] = Array.new

            seen.each do |key, weight|
                display_val = key[0]
                filter_val = key[1]

                point = {display_val: display_val,
                    filter_val: filter_val,
                    weight: weight,
                    location: loc}

                ans[loc].push(point)
                num_points += 1
            end
        end

        ans = {by_location: ans, num_points: num_points}
        return ans
    end

    # It decreases the number of points within each location by a scale factor.
    # The minimum size per location is 1 datapoint.
    # 
    # Params
    # by_location - A hash of datapoints. This has the same format as that returned by generate_raw_points.
    # 
    # Example: (Note that the locations are actually 5-digit FIPS codes)
    # by_location = { ... "alabama" => [1000 datapoints] ... }
    # condense_factor = 50
    # Returns { ... "alabama" => [20 datapoints] ... }
    def condense_by_location(by_location, condense_factor)
        num_points = 0

        by_location.each do |loc, points|
            target = [1, points.length * condense_factor].max

            while (points.length > target)
                to_merge = self.shrink_points(points)
                p1 = to_merge[0]
                p2 = to_merge[1]

                merged = self.merge_points(p1, p2)
                points.push(merged)
            end

            num_points += target

        end

        ans = {by_location: by_location, num_points: num_points}
        return ans
    end


    # Given a list `of points in one location, this method finds the two "best" points to merge.
    # It removes them from the original list of points and returns the two points.
    def shrink_points(points)
        p1 = points.delete_at(rand(points.length))
        p2 = points.delete_at(rand(points.length))
        return [p1, p2]
    end

    # Given two hashes that represent datapoints, returns a point that is the merged of the two.
    # The new point's display_val and filter_val will be an average of the originals. The weight will be the sum.
    # The two points must have the same location.
    def merge_points(p1, p2)
        # TODO: handle actually averaging them?
        display_val = (p1[:display_val].to_f*p1[:weight] + p2[:display_val].to_f*p2[:weight]) / (p1[:weight] + p2[:weight])
        filter_val = p1[:filter_val]
        location = p1[:location]
        weight = p1[:weight] + p2[:weight]

        merged = {display_val: display_val,
                    filter_val: filter_val,
                    weight: weight,
                    location: location}

        return merged
    end

end
