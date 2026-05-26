
require 'sketchup.rb'
require 'extensions.rb'
require 'set'

module AutoRender

  VERSION = '1.1.0' unless defined?(VERSION)

  DEFAULT_CONFIG = {

    crop_method: 'pixel_detect',

    uv_method: 'point_mapping',

    right_view_fix: 'none',

    enable_crop: true
  } unless defined?(DEFAULT_CONFIG)

  def self.load_chunky_png
    return true if defined?(ChunkyPNG) && ChunkyPNG.const_defined?(:Image)

    plugin_dir = File.dirname(__FILE__)
    chunky_png_dir = File.join(plugin_dir, 'chunky_png')

    chunky_png_paths = []

    plugin_lib_path = File.join(chunky_png_dir, 'lib')
    chunky_png_paths << plugin_lib_path if File.exist?(plugin_lib_path)

    chunky_png_paths << chunky_png_dir if File.exist?(chunky_png_dir)

    sketchup_versions = ['2026', '2025', '2024', '2023', '2022']
    sketchup_versions.each do |version|
      gems_paths = [
        File.join(ENV['APPDATA'] || '', 'SketchUp', "SketchUp #{version}", 'SketchUp', 'Gems64', 'gems', 'chunky_png-1.4.0', 'lib'),
        File.join(ENV['APPDATA'] || '', 'SketchUp', "SketchUp #{version}", 'SketchUp', 'Gems64', 'gems', 'chunky_png-1.4.0')
      ]
      gems_paths.each do |path|
        chunky_png_paths << path if path && File.exist?(path) && !chunky_png_paths.include?(path)
      end
    end

    if ENV['GEM_HOME']
      gem_home_path = File.join(ENV['GEM_HOME'], 'gems', 'chunky_png-1.4.0', 'lib')
      chunky_png_paths << gem_home_path if File.exist?(gem_home_path) && !chunky_png_paths.include?(gem_home_path)
    end

    if ENV['GEM_PATH']
      ENV['GEM_PATH'].split(File::PATH_SEPARATOR).each do |gem_path|
        gem_lib_path = File.join(gem_path, 'gems', 'chunky_png-1.4.0', 'lib')
        chunky_png_paths << gem_lib_path if File.exist?(gem_lib_path) && !chunky_png_paths.include?(gem_lib_path)
      end
    end

    chunky_png_paths.each do |path|
      begin
        $LOAD_PATH.unshift(path) if path && !$LOAD_PATH.include?(path)
        require 'chunky_png'

        if defined?(ChunkyPNG) && ChunkyPNG.const_defined?(:Image)
          return true
        end
      rescue LoadError, StandardError => e
        $LOAD_PATH.delete(path) if path
        next
      end
    end

    begin
      require 'chunky_png'
      return true if defined?(ChunkyPNG) && ChunkyPNG.const_defined?(:Image)
    rescue LoadError, StandardError

    end

    false
  end

  module HideEdges

    def self.hide_edges_recursive(entity)
      return 0 unless entity

      hidden_count = 0

      begin

        if entity.is_a?(Sketchup::Edge)
          unless entity.hidden?
            entity.hidden = true
            hidden_count += 1
          end

        elsif entity.is_a?(Sketchup::Group)
          entities = entity.entities
          if entities
            entities.each do |sub_entity|
              hidden_count += hide_edges_recursive(sub_entity)
            end
          end

        elsif entity.is_a?(Sketchup::ComponentInstance)
          definition = entity.definition
          if definition
            entities = definition.entities
            if entities
              entities.each do |sub_entity|
                hidden_count += hide_edges_recursive(sub_entity)
              end
            end
          end

        elsif entity.is_a?(Sketchup::Face)
          edges = entity.edges
          if edges
            edges.each do |edge|
              unless edge.hidden?
                edge.hidden = true
                hidden_count += 1
              end
            end
          end

        elsif entity.is_a?(Sketchup::Entities)
          entity.each do |sub_entity|
            hidden_count += hide_edges_recursive(sub_entity)
          end
        end
      rescue => e
        puts "处理实体时出错: #{e.message}"
        puts e.backtrace.join("\n")
      end

      hidden_count
    end
  end

  class AutoRenderTool

    def initialize
      @model = Sketchup.active_model
      @view = @model.active_view
      @original_layers = {}
      @original_rendering_options = nil
      @original_camera_perspective = nil
      @rendered_images = []
      @config = DEFAULT_CONFIG.dup
      @image_size = 512  
      @generated_component = nil  
    end

    def execute(mode = :five_views)
      begin

        selection = @model.selection
        if selection.empty?
          UI.messagebox("请先选择一个模型或组件！")
          return
        end

        image_size = get_render_resolution
        if image_size.nil?

          return nil
        end
        @image_size = image_size

        safe_execute("保存原始状态") { save_original_state }

        safe_execute("隐藏其他模型") { hide_other_entities(selection) }

        safe_execute("设置样式") { setup_rendering_style }

        case mode
        when :five_views
          execute_five_views(selection)
        when :face_camera
          execute_face_camera(selection)
        when :centered
          execute_centered(selection)
        else
          execute_five_views(selection)
        end

        restore_original_state

        if @generated_component
          safe_execute("隐藏组件边线") do
            if @generated_component.respond_to?(:valid?) && !@generated_component.valid?
              @generated_component = nil
            else
              @model.selection.clear
              @model.selection.add(@generated_component)
              HideEdges.hide_edges_recursive(@generated_component)
            end
          end
        end

        UI.messagebox("渲染完成！")

      rescue => e
        UI.messagebox("错误: #{e.message}\n#{e.backtrace.join("\n")}")
        restore_original_state
      end
    end

    def execute_five_views(selection)
      render_multiple_views(selection)
      process_images
      component_instance = place_images_as_textures
      select_and_hide_edges(component_instance)
    end

    def execute_face_camera(selection)
      render_single_view_face_camera(selection)
      process_images
      component_instance = place_single_face_centered(selection)
      select_and_hide_edges(component_instance)
    end

    def execute_centered(selection)
      render_multiple_views(selection)
      process_images
      component_instance = place_images_centered(selection)
      select_and_hide_edges(component_instance)
    end

    private

    def select_and_hide_edges(component_instance)
      return unless component_instance
      @generated_component = component_instance
      @model.selection.clear
      @model.selection.add(component_instance)
      HideEdges.hide_edges_recursive(component_instance)
    end

    def get_render_resolution

      prompts = ['渲染分辨率 (像素):']
      defaults = ['512']
      title = '设置渲染分辨率'

      input = UI.inputbox(prompts, defaults, title)

      return nil if input == false || input.nil? || (input.is_a?(Array) && input.empty?)

      begin
        resolution = input[0].to_i

        if resolution < 64
          UI.messagebox("分辨率太小，已设置为最小值 64")
          resolution = 64
        elsif resolution > 4096
          UI.messagebox("分辨率太大，已设置为最大值 4096")
          resolution = 4096
        end

        return resolution
      rescue => e
        UI.messagebox("输入无效，使用默认值 512\n错误: #{e.message}")
        return 512
      end
    end

    def save_original_state
      @model.start_operation('Auto Render', true)

      @model.layers.each do |layer|
        @original_layers[layer] = layer.visible?
      end

      rendering_options = @model.rendering_options
      @original_rendering_options = {}

      @original_rendering_options[:background_color] = safe_get_option(rendering_options, 'BackgroundColor') || safe_get_view_color
      @original_rendering_options[:display_sky] = safe_get_option(rendering_options, 'DisplaySky')
      @original_rendering_options[:sky_color] = safe_get_option(rendering_options, 'SkyColor')
      @original_rendering_options[:display_ground] = safe_get_option(rendering_options, 'DisplayGround')

      @original_camera_perspective = @view.camera.perspective?
      @original_camera_aspect_ratio = safe_get_camera_aspect_ratio
    end

    def safe_get_option(rendering_options, key)
      rendering_options[key] rescue nil
    end

    def safe_get_view_color
      @view.background_color rescue nil
    end

    def safe_get_camera_aspect_ratio
      @view.camera.aspect_ratio rescue nil
    end

    def copy_file_safe(input_file, output_file, message = nil)
      require 'fileutils'
      FileUtils.cp(input_file, output_file)
      puts message if message
    end

    def load_material_texture(material, file_path, error_message = nil)
      return unless material && file_path && File.exist?(file_path)
      material.texture = file_path
    rescue => e
      puts error_message || "加载纹理失败: #{e.message}"
    end

    def safe_execute(operation_name, &block)
      block.call
    rescue => e
      puts "#{operation_name}失败: #{e.message}"

    end

    def hide_other_entities(selection)

      selected_layers = Set.new
      selected_entities = Set.new
      selected_definitions = Set.new

      selection.each do |entity|
        collect_entities_and_layers(entity, selected_entities, selected_layers, selected_definitions)
      end

      @model.layers.each do |layer|
        unless selected_layers.include?(layer)
          layer.visible = false
        end
      end

      hide_entities_recursive(@model.active_entities, selected_entities, selected_definitions)
    end

    def hide_entities_recursive(entities, selected_entities, selected_definitions)
      entities.each do |entity|
        next if entity.is_a?(Sketchup::Layer)

        should_hide = true

        if entity.is_a?(Sketchup::ComponentInstance)
          if selected_entities.include?(entity) || selected_definitions.include?(entity.definition)
            should_hide = false
          end
        elsif entity.is_a?(Sketchup::Group)
          if selected_entities.include?(entity)
            should_hide = false
          else

            should_hide = !has_selected_entities(entity.entities, selected_entities, selected_definitions)
          end
        elsif selected_entities.include?(entity)
          should_hide = false
        end

        if should_hide && entity.respond_to?(:visible=)
          entity.visible = false
        elsif !should_hide && entity.is_a?(Sketchup::Group)

          hide_entities_recursive(entity.entities, selected_entities, selected_definitions)
        end
      end
    end

    def has_selected_entities(entities, selected_entities, selected_definitions)
      entities.each do |entity|
        return true if selected_entities.include?(entity)
        if entity.is_a?(Sketchup::ComponentInstance)
          return true if selected_definitions.include?(entity.definition)
        end
        if entity.is_a?(Sketchup::Group)
          return true if has_selected_entities(entity.entities, selected_entities, selected_definitions)
        end
      end
      false
    end

    def collect_entities_and_layers(entity, entities_set, layers_set, definitions_set)
      entities_set.add(entity)

      if entity.respond_to?(:layer)
        layers_set.add(entity.layer) if entity.layer
      end

      if entity.is_a?(Sketchup::ComponentInstance)
        definitions_set.add(entity.definition)

        entity.definition.entities.each do |sub_entity|
          collect_entities_and_layers(sub_entity, entities_set, layers_set, definitions_set)
        end
      elsif entity.is_a?(Sketchup::Group)
        entity.entities.each do |sub_entity|
          collect_entities_and_layers(sub_entity, entities_set, layers_set, definitions_set)
        end
      end
    end

    def setup_rendering_style
      rendering_options = @model.rendering_options

      bg_color_set = false
      begin

        bg_color = Sketchup::Color.new(255, 255, 255)
        rendering_options['BackgroundColor'] = bg_color
        bg_color_set = true
      rescue => e1
        begin

          rendering_options['BackgroundColor'] = [255, 255, 255]
          bg_color_set = true
        rescue => e2
          begin

            rendering_options['BackgroundColor'] = Sketchup::Color.new(255, 255, 255)
            bg_color_set = true
          rescue => e3

            begin
              @view.background_color = Sketchup::Color.new(255, 255, 255)
              bg_color_set = true
            rescue => e4
              puts "警告: 无法设置背景颜色"
            end
          end
        end
      end

      sky_color_set = false
      begin
        sky_color = Sketchup::Color.new(255, 255, 255)
        rendering_options['SkyColor'] = sky_color
        sky_color_set = true
      rescue => e

      end

      display_sky_set = false
      begin
        if rendering_options.respond_to?(:[]=)
          rendering_options['DisplaySky'] = false
          display_sky_set = true
        elsif rendering_options.respond_to?(:display_sky=)
          rendering_options.display_sky = false
          display_sky_set = true
        end
      rescue => e

      end

      begin
        if rendering_options.respond_to?(:[]=)
          rendering_options['DisplayGround'] = false
        elsif rendering_options.respond_to?(:display_ground=)
          rendering_options.display_ground = false
        end
      rescue => e

      end

      @view.refresh
    end

    def render_multiple_views(selection)

      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      bounding_box = bounding_box_info[:bounding_box]
      return if bounding_box.empty?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]

      min_point = bounding_box.min
      max_point = bounding_box.max
      center = bounding_box.center

      width = bounding_box.width
      height_bb = bounding_box.height
      depth = bounding_box.depth
      max_dimension = [width, height_bb, depth].max

      model_pixel_size = @image_size * 0.8
      camera_height = max_dimension * (@image_size / model_pixel_size)

      if local_bounds && transformation && !local_bounds.empty?

        views = calculate_aligned_views(local_bounds, transformation, bounding_box)
      else

        views = calculate_simple_views(bounding_box)
      end

      views.each do |view_config|
        render_view(view_config, bounding_box, camera_height)
      end
    end

    def render_single_view(selection, view_name)

      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      bounding_box = bounding_box_info[:bounding_box]
      return if bounding_box.empty?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]

      width = bounding_box.width
      height_bb = bounding_box.height
      depth = bounding_box.depth
      max_dimension = [width, height_bb, depth].max

      model_pixel_size = @image_size * 0.8
      camera_height = max_dimension * (@image_size / model_pixel_size)

      if local_bounds && transformation && !local_bounds.empty?
        views = calculate_aligned_views(local_bounds, transformation, bounding_box)
      else
        views = calculate_simple_views(bounding_box)
      end

      view_config = views.find { |v| v[:name] == view_name }
      return unless view_config

      render_view(view_config, bounding_box, camera_height)
    end

    def render_single_view_face_camera(selection)

      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      bounding_box = bounding_box_info[:bounding_box]
      return if bounding_box.empty?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]

      width = bounding_box.width
      height_bb = bounding_box.height
      depth = bounding_box.depth
      max_dimension = [width, height_bb, depth].max

      model_pixel_size = @image_size * 0.8
      camera_height = max_dimension * (@image_size / model_pixel_size)

      if local_bounds && transformation && !local_bounds.empty?
        view_config = calculate_front_view_aligned(local_bounds, transformation, bounding_box)
      else
        view_config = calculate_front_view_simple(bounding_box)
      end

      return unless view_config

      render_view(view_config, bounding_box, camera_height)
    end

    def calculate_front_view_aligned(local_bounds, transformation, global_bounds)
      width = local_bounds.width
      height = local_bounds.height
      depth = local_bounds.depth

      width = [width, 999999].min
      height = [height, 999999].min
      depth = [depth, 999999].min

      if width <= 0 || height <= 0 || depth <= 0
        return nil
      end

      local_center = local_bounds.center
      max_dimension = [width, height, depth].max
      camera_distance = max_dimension * 2.0

      local_normal = Geom::Vector3d.new(0, 1, 0)  
      local_up = Geom::Vector3d.new(0, 0, 1)

      global_center = transformation * local_center

      origin = Geom::Point3d.new(0, 0, 0)
      transformed_origin = transformation * origin

      local_normal_point = origin + local_normal
      local_up_point = origin + local_up

      global_normal_point = transformation * local_normal_point
      global_up_point = transformation * local_up_point

      global_normal = Geom::Vector3d.new(
        global_normal_point.x - transformed_origin.x,
        global_normal_point.y - transformed_origin.y,
        global_normal_point.z - transformed_origin.z
      )
      global_up = Geom::Vector3d.new(
        global_up_point.x - transformed_origin.x,
        global_up_point.y - transformed_origin.y,
        global_up_point.z - transformed_origin.z
      )

      if global_normal.length < 1e-10 || global_up.length < 1e-10
        puts "警告: 向量长度过小，使用默认值"
        global_normal = Geom::Vector3d.new(0, 1, 0)
        global_up = Geom::Vector3d.new(0, 0, 1)
      end

      unless global_normal.is_a?(Geom::Vector3d)
        puts "警告: global_normal不是Vector3d，使用默认值"
        global_normal = Geom::Vector3d.new(0, 1, 0)
      end

      unless global_up.is_a?(Geom::Vector3d)
        puts "警告: global_up不是Vector3d，使用默认值"
        global_up = Geom::Vector3d.new(0, 0, 1)
      end

      begin
        global_normal.normalize!
        global_up.normalize!
      rescue => e
        puts "向量归一化失败: #{e.message}，使用默认值"
        global_normal = Geom::Vector3d.new(0, 1, 0)
        global_up = Geom::Vector3d.new(0, 0, 1)
      end

      begin
        camera_distance = camera_distance.to_f
        if camera_distance <= 0 || camera_distance.nan? || camera_distance.infinite?
          camera_distance = max_dimension * 2.0
        end
      rescue => e
        puts "camera_distance转换失败: #{e.message}，使用默认值"
        camera_distance = max_dimension * 2.0
      end

      unless global_normal.is_a?(Geom::Vector3d) && global_normal.valid?
        puts "警告: global_normal无效，使用默认值"
        global_normal = Geom::Vector3d.new(0, 1, 0)
      end

      begin

        camera_distance_float = camera_distance.to_f
        if camera_distance_float.nan? || camera_distance_float.infinite? || camera_distance_float <= 0
          camera_distance_float = max_dimension * 2.0
        end

        unless global_normal.is_a?(Geom::Vector3d)
          global_normal = Geom::Vector3d.new(0, 1, 0)
        end

        camera_distance_vector = global_normal.clone
        camera_distance_vector.length = camera_distance_float
        camera_eye = global_center - camera_distance_vector
      rescue => e
        puts "计算相机位置失败: #{e.message}，使用默认位置"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"

        default_distance = max_dimension * 2.0
        camera_eye = global_center - Geom::Vector3d.new(0, 1, 0) * default_distance
      end

      min_point = global_bounds.min
      max_point = global_bounds.max

      {
        name: 'front',
        eye: camera_eye,
        target: global_center,
        up: global_up,
        direction: global_normal,
        min_point: min_point,
        max_point: max_point,
        view_width: width,
        view_height: depth,
        view_dimension: [width, depth].max
      }
    end

    def calculate_front_view_simple(bounding_box)
      min_point = bounding_box.min
      max_point = bounding_box.max
      center = bounding_box.center

      width = bounding_box.width
      depth = bounding_box.depth

      {
        name: 'front',
        eye: center + Geom::Vector3d.new(0, -1, 0),  
        target: center,
        up: Geom::Vector3d.new(0, 0, 1),
        direction: Geom::Vector3d.new(0, 1, 0),  
        min_point: min_point,
        max_point: max_point,
        view_width: width,
        view_height: max_point.z - min_point.z,
        view_dimension: [width, depth].max
      }
    end

    def get_selection_bounding_box_with_transform(selection)
      entities = selection.to_a
      return nil if entities.empty?

      if entities.length == 1 && (entities[0].is_a?(Sketchup::Group) || entities[0].is_a?(Sketchup::ComponentInstance))
        entity = entities[0]
        transformation = entity.transformation

        local_bounds = nil
        if entity.is_a?(Sketchup::Group)

          local_bounds = Geom::BoundingBox.new
          entity.entities.each do |ent|
            if ent.respond_to?(:bounds)
              local_bounds.add(ent.bounds)
            end
          end
        else

          local_bounds = entity.definition.bounds
        end

        global_bounds = entity.bounds

        if local_bounds && !local_bounds.empty? && global_bounds && !global_bounds.empty?
          return {
            bounding_box: global_bounds,
            local_bounds: local_bounds,
            transformation: transformation
          }
        end
      end

      bounding_box = Geom::BoundingBox.new
      entities.each do |entity|
        if entity.respond_to?(:bounds)
          bounding_box.add(entity.bounds)
        end
      end

      return {
        bounding_box: bounding_box,
        local_bounds: nil,
        transformation: nil
      }
    end

    def calculate_aligned_views(local_bounds, transformation, global_bounds)

      width = local_bounds.width
      height = local_bounds.height
      depth = local_bounds.depth

      width = [width, 999999].min
      height = [height, 999999].min
      depth = [depth, 999999].min

      if width <= 0 || height <= 0 || depth <= 0

        return calculate_simple_views(global_bounds)
      end

      local_center = local_bounds.center

      max_dimension = [width, height, depth].max
      camera_distance = max_dimension * 2.0

      face_configs = [
        {
          name: 'top',

          local_center_offset: Geom::Point3d.new(0, 0, depth/2),
          local_normal: Geom::Vector3d.new(0, 0, 1),
          local_up: Geom::Vector3d.new(0, 1, 0),
          view_index: 0,
          view_dimension: [width, height].max
        },
        {
          name: 'left',

          local_center_offset: Geom::Point3d.new(-width/2, 0, 0),
          local_normal: Geom::Vector3d.new(-1, 0, 0),
          local_up: Geom::Vector3d.new(0, 0, 1),
          view_index: 1,
          view_dimension: [height, depth].max
        },
        {
          name: 'right',

          local_center_offset: Geom::Point3d.new(width/2, 0, 0),
          local_normal: Geom::Vector3d.new(1, 0, 0),
          local_up: Geom::Vector3d.new(0, 0, 1),
          view_index: 2,
          view_dimension: [height, depth].max
        },
        {
          name: 'front',

          local_center_offset: Geom::Point3d.new(0, height/2, 0),
          local_normal: Geom::Vector3d.new(0, 1, 0),
          local_up: Geom::Vector3d.new(0, 0, 1),
          view_index: 3,
          view_dimension: [width, depth].max
        },
        {
          name: 'back',

          local_center_offset: Geom::Point3d.new(0, -height/2, 0),
          local_normal: Geom::Vector3d.new(0, -1, 0),
          local_up: Geom::Vector3d.new(0, 0, 1),
          view_index: 4,
          view_dimension: [width, depth].max
        }
      ]

      min_point = global_bounds.min
      max_point = global_bounds.max

      views = []
      face_configs.each do |face_config|

        local_face_center = Geom::Point3d.new(
          local_center.x + face_config[:local_center_offset].x,
          local_center.y + face_config[:local_center_offset].y,
          local_center.z + face_config[:local_center_offset].z
        )

        global_center = transformation * local_face_center

        origin = Geom::Point3d.new(0, 0, 0)
        transformed_origin = transformation * origin

        local_normal_point = origin + face_config[:local_normal]
        local_up_point = origin + face_config[:local_up]

        global_normal_point = transformation * local_normal_point
        global_up_point = transformation * local_up_point

        global_normal = Geom::Vector3d.new(
          global_normal_point.x - transformed_origin.x,
          global_normal_point.y - transformed_origin.y,
          global_normal_point.z - transformed_origin.z
        )
        global_up = Geom::Vector3d.new(
          global_up_point.x - transformed_origin.x,
          global_up_point.y - transformed_origin.y,
          global_up_point.z - transformed_origin.z
        )

        global_normal.normalize!
        global_up.normalize!

        camera_eye = Geom::Point3d.new(
          global_center.x + global_normal.x * camera_distance,
          global_center.y + global_normal.y * camera_distance,
          global_center.z + global_normal.z * camera_distance
        )

        view_dimension = face_config[:view_dimension]

        view_width, view_height = case face_config[:name]
        when 'top'
          [width, height]
        when 'left', 'right'
          [height, depth]
        when 'front', 'back'
          [width, depth]
        else
          [width, height]
        end

        views << {
          name: face_config[:name],
          eye: camera_eye,
          target: global_center,
          up: global_up,
          direction: global_normal,

          min_point: min_point,
          max_point: max_point,
          view_width: view_width,
          view_height: view_height,

          view_dimension: view_dimension
        }
      end

      views
    end

    def calculate_simple_views(bounding_box)
      min_point = bounding_box.min
      max_point = bounding_box.max
      center = bounding_box.center

      width = bounding_box.width
      height_bb = bounding_box.height
      depth = bounding_box.depth

      [
        {
          name: 'front',
          eye: center + Geom::Vector3d.new(0, -1, 0),
          target: center,
          up: Geom::Vector3d.new(0, 0, 1),
          direction: Geom::Vector3d.new(0, 1, 0),
          min_point: min_point,
          max_point: max_point,
          view_width: width,
          view_height: max_point.z - min_point.z,
          view_dimension: [width, depth].max
        },
        {
          name: 'back',
          eye: center + Geom::Vector3d.new(0, 1, 0),
          target: center,
          up: Geom::Vector3d.new(0, 0, 1),
          direction: Geom::Vector3d.new(0, -1, 0),
          min_point: min_point,
          max_point: max_point,
          view_width: width,
          view_height: max_point.z - min_point.z,
          view_dimension: [width, depth].max
        },
        {
          name: 'top',
          eye: center + Geom::Vector3d.new(0, 0, -1),
          target: center,
          up: Geom::Vector3d.new(0, 1, 0),
          direction: Geom::Vector3d.new(0, 0, 1),
          min_point: min_point,
          max_point: max_point,
          view_width: width,
          view_height: height_bb,
          view_dimension: [width, height_bb].max
        },
        {
          name: 'right',
          eye: center + Geom::Vector3d.new(1, 0, 0),
          target: center,
          up: Geom::Vector3d.new(0, 0, 1),
          direction: Geom::Vector3d.new(-1, 0, 0),
          min_point: min_point,
          max_point: max_point,
          view_width: depth,
          view_height: max_point.z - min_point.z,
          view_dimension: [height_bb, depth].max
        },
        {
          name: 'left',
          eye: center + Geom::Vector3d.new(-1, 0, 0),
          target: center,
          up: Geom::Vector3d.new(0, 0, 1),
          direction: Geom::Vector3d.new(1, 0, 0),
          min_point: min_point,
          max_point: max_point,
          view_width: depth,
          view_height: max_point.z - min_point.z,
          view_dimension: [height_bb, depth].max
        }
      ]
    end

    def get_selection_bounding_box(selection)
      bounding_box = Geom::BoundingBox.new

      selection.each do |entity|
        if entity.respond_to?(:bounds)
          bounding_box.add(entity.bounds)
        end
      end

      bounding_box
    end

    def render_view(view_config, bounding_box, camera_height)

      camera = @view.camera
      original_perspective = camera.perspective?
      camera.perspective = false

      if view_config[:eye] && view_config[:target] && view_config[:up]

        eye = view_config[:eye]
        target = view_config[:target]
        up = view_config[:up]
      else

      diagonal_length = bounding_box.diagonal
      distance_value = diagonal_length.to_f * 2.0

      direction_vector = view_config[:direction]
      target_point = view_config[:target]

      unless direction_vector.is_a?(Geom::Vector3d)
        direction_vector = Geom::Vector3d.new(direction_vector)
      end

      direction_vector.normalize!
      scaled_direction = Geom::Vector3d.new(
        direction_vector.x * distance_value,
        direction_vector.y * distance_value,
        direction_vector.z * distance_value
      )

      eye = target_point + scaled_direction
        target = target_point
        up = view_config[:up]
      end

      camera.set(eye, target, up)

      if view_config[:view_dimension]

        view_dimension = view_config[:view_dimension]
        camera.height = view_dimension * 1.1
      else

      camera.height = camera_height
      end

      @view.refresh

      sleep(0.2)

      temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || '/tmp', 'sketchup_render')
      Dir.mkdir(temp_dir) unless Dir.exist?(temp_dir)
      temp_file = File.join(temp_dir, "#{view_config[:name]}_temp.png")

      success = @view.write_image(
        temp_file,
        @image_size,
        @image_size,
        true,  
        1.0    
      )

      if success && File.exist?(temp_file)

        image = Sketchup::ImageRep.new(temp_file)

        @rendered_images << {
          name: view_config[:name],
          image: image,
          bounding_box: bounding_box,
          temp_file: temp_file,
          view_config: view_config,  

          model_width: bounding_box.width,
          model_height: bounding_box.height,
          model_depth: bounding_box.depth
        }
      end
    end

    def process_images
      @rendered_images.each do |item|
        temp_file = item[:temp_file]
        name = item[:name]

        next unless temp_file && File.exist?(temp_file)

        temp_dir = File.dirname(temp_file)
        cropped_file = File.join(temp_dir, "#{name}_cropped.png")
        final_file = File.join(temp_dir, "#{name}_transparent.png")

        if @config[:enable_crop]
          crop_image_to_model(temp_file, cropped_file, item)
        else
          require 'fileutils'
          FileUtils.cp(temp_file, cropped_file)
        end

        remove_white_background(cropped_file, final_file)

        item[:file_path] = final_file
      end
    end

    def crop_image_to_model(input_file, output_file, item)
      return unless item[:view_config]

      view_config = item[:view_config]
      view_name = item[:name]

      crop_by_pixel_detection(input_file, output_file, item)
    end

    def crop_by_pixel_detection(input_file, output_file, item)
      begin

        unless AutoRender.load_chunky_png
          raise LoadError, "无法加载 chunky_png 库"
        end
        image = ChunkyPNG::Image.from_file(input_file)

        white_threshold = 240
        min_x = image.width
        min_y = image.height
        max_x = 0
        max_y = 0

        image.height.times do |y|
          image.width.times do |x|
            pixel = image[x, y]
            r = ChunkyPNG::Color.r(pixel)
            g = ChunkyPNG::Color.g(pixel)
            b = ChunkyPNG::Color.b(pixel)

            unless r >= white_threshold && g >= white_threshold && b >= white_threshold
              min_x = [min_x, x].min
              min_y = [min_y, y].min
              max_x = [max_x, x].max
              max_y = [max_y, y].max
            end
          end
        end

        if min_x < max_x && min_y < max_y
          padding = 10  
          crop_x = [0, min_x - padding].max
          crop_y = [0, min_y - padding].max
          crop_width = [[image.width - crop_x, max_x - crop_x + padding * 2].min, 1].max
          crop_height = [[image.height - crop_y, max_y - crop_y + padding * 2].min, 1].max

          perform_crop(image, crop_x, crop_y, crop_width, crop_height, output_file, input_file, item[:name])
        else
          copy_file_safe(input_file, output_file, "像素检测未找到模型区域，使用原图")
        end
      rescue LoadError
        copy_file_safe(input_file, output_file, "无法加载chunky_png，使用原图")
      rescue => e
        copy_file_safe(input_file, output_file, "像素检测失败: #{e.message}，使用原图")
      end
    end

    def perform_crop(image, crop_x, crop_y, crop_width, crop_height, output_file, input_file, view_name)

      crop_x = [0, [crop_x, image.width - 1].min].max
      crop_y = [0, [crop_y, image.height - 1].min].max
      crop_width = [1, [crop_width, image.width - crop_x].min].max
      crop_height = [1, [crop_height, image.height - crop_y].min].max

      if crop_x + crop_width > image.width
        crop_width = image.width - crop_x
      end
      if crop_y + crop_height > image.height
        crop_height = image.height - crop_y
      end

      if crop_width > 0 && crop_height > 0 && crop_x >= 0 && crop_y >= 0

        cropped_image = image.crop(crop_x, crop_y, crop_width, crop_height)

        output_dir = File.dirname(output_file)
        FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir)

        cropped_image.save(output_file)

        unless File.exist?(output_file) && File.size(output_file) > 0
          copy_file_safe(input_file, output_file, "警告: 裁剪后的文件保存失败，使用原图")
        end
      else
        copy_file_safe(input_file, output_file, "警告: 裁剪区域无效 (#{crop_x},#{crop_y} #{crop_width}x#{crop_height})，使用原图")
      end
    rescue => e
      copy_file_safe(input_file, output_file, "裁切执行失败: #{e.message}，使用原图")
    end

    def perform_crop_imagemagick(input_file, crop_x, crop_y, crop_width, crop_height, output_file, view_name)
      magick_cmd = get_imagemagick_command('magick')
      convert_cmd = get_imagemagick_command('convert')

      if magick_cmd
        crop_geometry = "#{crop_width}x#{crop_height}+#{crop_x}+#{crop_y}"
        result = system("\"#{magick_cmd}\" \"#{input_file}\" -crop #{crop_geometry} \"#{output_file}\"")
        unless result && File.exist?(output_file) && File.size(output_file) > 0
          copy_file_safe(input_file, output_file, "警告: ImageMagick裁剪失败，使用原图")
        end
      elsif convert_cmd
        crop_geometry = "#{crop_width}x#{crop_height}+#{crop_x}+#{crop_y}"
        result = system("\"#{convert_cmd}\" \"#{input_file}\" -crop #{crop_geometry} \"#{output_file}\"")
        unless result && File.exist?(output_file) && File.size(output_file) > 0
          copy_file_safe(input_file, output_file, "警告: ImageMagick convert裁剪失败，使用原图")
        end
      else
        copy_file_safe(input_file, output_file, "警告: 未找到图片处理工具，无法裁剪，使用原图")
      end
    end

    def remove_white_background(input_file, output_file)

      chunky_png_available = AutoRender.load_chunky_png
      chunky_png_error = nil

      unless chunky_png_available
        chunky_png_error = "无法从插件目录或系统路径加载 chunky_png"
      end

      if chunky_png_available
        begin
          image = ChunkyPNG::Image.from_file(input_file)
          white_threshold = 240  

          image.pixels.map!.with_index do |pixel, index|
            r = ChunkyPNG::Color.r(pixel)
            g = ChunkyPNG::Color.g(pixel)
            b = ChunkyPNG::Color.b(pixel)
            a = ChunkyPNG::Color.a(pixel)

            if r >= white_threshold && g >= white_threshold && b >= white_threshold

              if ChunkyPNG::Color.const_defined?(:TRANSPARENT)
                ChunkyPNG::Color::TRANSPARENT
              else

                ChunkyPNG::Color.rgba(0, 0, 0, 0)
              end
            else

              ChunkyPNG::Color.rgba(r, g, b, a)
            end
          end

          image.save(output_file)
          return  
        rescue => e

          chunky_png_error = "chunky_png处理失败: #{e.message}"
          puts chunky_png_error
        end
      end

      imagemagick_used = false
      magick_cmd = get_imagemagick_command('magick')
      convert_cmd = get_imagemagick_command('convert')

      if magick_cmd
        result = system("\"#{magick_cmd}\" \"#{input_file}\" -fuzz 10% -transparent white \"#{output_file}\"")
        if result && File.exist?(output_file)
          imagemagick_used = true
          return  
        end
      elsif convert_cmd
        result = system("\"#{convert_cmd}\" \"#{input_file}\" -fuzz 10% -transparent white \"#{output_file}\"")
        if result && File.exist?(output_file)
          imagemagick_used = true
          return  
        end
      end

      require 'fileutils'
      FileUtils.cp(input_file, output_file)

      error_msg = "警告: 无法扣除背景，已使用原始图片。\n\n"

      if chunky_png_error
        error_msg += "chunky_png状态: #{chunky_png_error}\n\n"
      elsif !chunky_png_available
        error_msg += "chunky_png: 未安装或无法加载\n\n"
      end

      unless imagemagick_used
        if !system_command_available?('magick') && !system_command_available?('convert')
          error_msg += "ImageMagick: 未安装或不在PATH中\n\n"
        end
      end

      error_msg += "解决方案：\n"
      error_msg += "1. 将 chunky_png 库放在插件目录下的 chunky_png 文件夹中：\n"
      error_msg += "   插件目录: #{File.dirname(__FILE__)}\n"
      error_msg += "   将 chunky_png 库解压到: #{File.join(File.dirname(__FILE__), 'chunky_png')}\n"
      error_msg += "   确保 chunky_png.rb 文件在 chunky_png/lib/ 目录下\n"
      error_msg += "2. 或者在SketchUp的Ruby环境中安装chunky_png:\n"
      error_msg += "   打开Ruby控制台，运行: require 'rubygems'; gem 'chunky_png'\n"
      error_msg += "   或使用SketchUp的Ruby: gem install chunky_png\n"
      error_msg += "3. 安装ImageMagick并确保在系统PATH中\n"
      error_msg += "   https://imagemagick.org/"

      UI.messagebox(error_msg)
    end

    def system_command_available?(cmd)
      if RUBY_PLATFORM =~ /mswin|mingw|cygwin/

        if system("where #{cmd} >nul 2>&1")
          return true
        end

        common_paths = [
          'C:\\Program Files\\ImageMagick-7.1.2-Q16',
          'C:\\Program Files\\ImageMagick-7.1.1-Q16',
          'C:\\Program Files\\ImageMagick-7.1.0-Q16',
          'C:\\Program Files\\ImageMagick-7.0.*',
          'C:\\Program Files (x86)\\ImageMagick-7.*',
          'C:\\Program Files\\ImageMagick'
        ]
        common_paths.each do |path|

          if path.include?('*')
            Dir.glob(path).each do |full_path|
              exe_path = File.join(full_path, "#{cmd}.exe")
              if File.exist?(exe_path)
                return true
              end
            end
          else
            exe_path = File.join(path, "#{cmd}.exe")
            if File.exist?(exe_path)
              return true
            end
          end
        end
        false
      else
        system("which #{cmd} >/dev/null 2>&1")
      end
    end

    def get_imagemagick_command(cmd)
      if RUBY_PLATFORM =~ /mswin|mingw|cygwin/

        result = `where #{cmd} 2>NUL`.strip
        if result && !result.empty? && File.exist?(result.split("\n").first)
          return result.split("\n").first
        end

        common_paths = [
          'C:\\Program Files\\ImageMagick-7.1.2-Q16',
          'C:\\Program Files\\ImageMagick-7.1.1-Q16',
          'C:\\Program Files\\ImageMagick-7.1.0-Q16',
          'C:\\Program Files\\ImageMagick-7.0.*',
          'C:\\Program Files (x86)\\ImageMagick-7.*',
          'C:\\Program Files\\ImageMagick'
        ]
        common_paths.each do |path|

          if path.include?('*')
            Dir.glob(path).each do |full_path|
              exe_path = File.join(full_path, "#{cmd}.exe")
              if File.exist?(exe_path)
                return exe_path
              end
            end
          else
            exe_path = File.join(path, "#{cmd}.exe")
            if File.exist?(exe_path)
              return exe_path
            end
          end
        end
        nil
      else
        result = `which #{cmd} 2>/dev/null`.strip
        return result if result && !result.empty?
        nil
      end
    end

    def place_images_as_textures
      return if @rendered_images.empty?

      selection = @model.selection
      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]
      global_bounds = bounding_box_info[:bounding_box]

      materials = @model.materials
      transparent_material = materials.add("AutoRender_Transparent_#{Time.now.to_i}")
      begin
        transparent_material.color = Sketchup::Color.new(255, 255, 255, 0)
        transparent_material.alpha = 0.0 if transparent_material.respond_to?(:alpha=)
      rescue => e
        puts "创建透明材质失败: #{e.message}"
        transparent_material = nil
      end

      if local_bounds && transformation && !local_bounds.empty?

        group = create_aligned_faces_group(local_bounds, transformation, transparent_material)
      else

        group = create_simple_faces_group(global_bounds, transparent_material)
      end

      component_instance = nil
      if group
        component_instance = convert_group_to_component(group)
      end

      if component_instance
        apply_transparent_back_material_to_component(component_instance)

        fix_component_material_uv(component_instance)
      end

      component_instance
    end

    def create_aligned_faces_group(local_bounds, transformation, transparent_material)

      width = local_bounds.width
      height = local_bounds.height
      depth = local_bounds.depth

      width = [width, 999999].min
      height = [height, 999999].min
      depth = [depth, 999999].min

      if width <= 0 || height <= 0 || depth <= 0
        return nil
      end

      local_center = local_bounds.center

      entities = @model.active_entities
      group = entities.add_group

      created_faces = {}

      @rendered_images.each do |item|
        file_path = item[:file_path]
        next unless file_path && File.exist?(file_path)

        materials = @model.materials
        material = materials.add("AutoRender_#{item[:name]}_#{Time.now.to_i}")

        load_material_texture(material, file_path) || next

        face_config = case item[:name]
        when 'top'

          {
            local_center: Geom::Point3d.new(0, 0, -depth/2),
            local_normal: Geom::Vector3d.new(0, 0, -1),
            local_up: Geom::Vector3d.new(0, 1, 0),
            face_width: width,
            face_height: height
          }
        when 'left'

          {
            local_center: Geom::Point3d.new(width/2, 0, 0),
            local_normal: Geom::Vector3d.new(1, 0, 0),
            local_up: Geom::Vector3d.new(0, 0, 1),
            face_width: height,
            face_height: depth
          }
        when 'right'

          {
            local_center: Geom::Point3d.new(-width/2, 0, 0),
            local_normal: Geom::Vector3d.new(-1, 0, 0),
            local_up: Geom::Vector3d.new(0, 0, 1),
            face_width: height,
            face_height: depth
          }
        when 'front'

          {
            local_center: Geom::Point3d.new(0, -height/2, 0),
            local_normal: Geom::Vector3d.new(0, -1, 0),
            local_up: Geom::Vector3d.new(0, 0, 1),
            face_width: width,
            face_height: depth
          }
        when 'back'

          {
            local_center: Geom::Point3d.new(0, height/2, 0),
            local_normal: Geom::Vector3d.new(0, 1, 0),
            local_up: Geom::Vector3d.new(0, 0, 1),
            face_width: width,
            face_height: depth
          }
        else
          next
        end

        face = create_texture_plane_in_group(
          group,
          face_config[:local_center],
          face_config[:local_normal],
          face_config[:local_up],
          face_config[:face_width],
          face_config[:face_height],
          material,
          item
        )

        if face

          face.reverse!

          if ['front', 'back', 'left', 'right'].include?(item[:name]) && transparent_material
            face.back_material = transparent_material
          end

          if item[:name] == 'top'
            flip_texture_horizontally_front(face, material)
          end

          created_faces[item[:name]] = face
        end
      end

      if created_faces.empty?
        group.erase!
        return nil
      end

      move_to_local_center = Geom::Transformation.translation(local_center)
      final_transformation = transformation * move_to_local_center

      group.transformation = final_transformation

      group
    end

    def create_simple_faces_group(global_bounds, transparent_material)
      center = global_bounds.center
      min_point = global_bounds.min
      max_point = global_bounds.max

      width = global_bounds.width
      height_bb = global_bounds.height
      depth = global_bounds.depth

      entities = @model.active_entities
      group = entities.add_group

      created_faces = {}

      @rendered_images.each do |item|
        file_path = item[:file_path]
        next unless file_path && File.exist?(file_path)

        materials = @model.materials
        material = materials.add("AutoRender_#{item[:name]}_#{Time.now.to_i}")

        load_material_texture(material, file_path) || next

        case item[:name]
        when 'front'
          face_width = width
          face_height = max_point.z - min_point.z

          local_position = Geom::Point3d.new(0, min_point.y - center.y - 0.01, 0)
          normal = Geom::Vector3d.new(0, 1, 0)
          up = Geom::Vector3d.new(0, 0, 1)
        when 'back'
          face_width = width
          face_height = max_point.z - min_point.z

          local_position = Geom::Point3d.new(0, max_point.y - center.y + 0.01, 0)
          normal = Geom::Vector3d.new(0, -1, 0)
          up = Geom::Vector3d.new(0, 0, 1)
        when 'left'
          face_width = height_bb
          face_height = max_point.z - min_point.z

          local_position = Geom::Point3d.new(min_point.x - center.x - 0.01, 0, 0)
          normal = Geom::Vector3d.new(1, 0, 0)
          up = Geom::Vector3d.new(0, 0, 1)
        when 'right'
          face_width = height_bb
          face_height = max_point.z - min_point.z

          local_position = Geom::Point3d.new(max_point.x - center.x + 0.01, 0, 0)
          normal = Geom::Vector3d.new(-1, 0, 0)
          up = Geom::Vector3d.new(0, 0, 1)
        when 'top'
          face_width = width
          face_height = height_bb
          local_position = Geom::Point3d.new(0, 0, min_point.z - center.z - 0.01)
          normal = Geom::Vector3d.new(0, 0, -1)  
          up = Geom::Vector3d.new(0, 1, 0)
        else
          next
        end

        if face_width > 0 && face_height > 0

          face = create_texture_plane_in_group(
            group,
            local_position,
            normal,
            up,
            face_width,
            face_height,
            material,
            item
          )

          if face

            face.reverse!

            if ['front', 'back', 'left', 'right'].include?(item[:name]) && transparent_material
              face.back_material = transparent_material
            end

            if item[:name] == 'top'
              flip_texture_horizontally_front(face, material)
            end

            created_faces[item[:name]] = face
          end
        end
      end

      if created_faces.empty?
        group.erase!
        return nil
      end

      translation = Geom::Transformation.translation(center)
      group.transformation = translation

      group
    end

    def create_texture_plane_in_group(group, center, normal, up, width, height, material, item = nil)
      width = width.to_f
      height = height.to_f

      if width <= 0 || height <= 0
        puts "警告: 纹理平面尺寸无效，跳过创建"
        return nil
      end

      entities = group.entities

      if normal == Geom::Vector3d.new(0, 1, 0)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(0, -1, 0)

        right = Geom::Vector3d.new(-1, 0, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(0, 0, -1)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, 1, 0)
      elsif normal == Geom::Vector3d.new(0, 0, 1)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, -1, 0)
      elsif normal == Geom::Vector3d.new(-1, 0, 0)

        right = Geom::Vector3d.new(0, 1, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(1, 0, 0)

        right = Geom::Vector3d.new(0, -1, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      else

        right = up * normal
        unless right.is_a?(Geom::Vector3d)
          right = Geom::Vector3d.new(right)
        end

        if right.length < 0.001

          if normal == Geom::Vector3d.new(0, 0, 1) || normal == Geom::Vector3d.new(0, 0, -1)
            right = Geom::Vector3d.new(1, 0, 0)
          else
            right = Geom::Vector3d.new(0, 0, 1) * normal
            unless right.is_a?(Geom::Vector3d)
              right = Geom::Vector3d.new(right)
            end
          end
        end

        right.normalize!
        up.normalize!
      end

      right.normalize! unless right.length == 1.0
      up.normalize! unless up.length == 1.0

      half_width = width / 2.0
      half_height = height / 2.0

      right_scaled = Geom::Vector3d.new(right.x * half_width, right.y * half_width, right.z * half_width)
      up_scaled = Geom::Vector3d.new(up.x * half_height, up.y * half_height, up.z * half_height)

      p1 = center - right_scaled - up_scaled
      p2 = center + right_scaled - up_scaled
      p3 = center + right_scaled + up_scaled
      p4 = center - right_scaled + up_scaled

      points = [p1, p2, p3, p4]
      unique_points = []
      points.each do |pt|
        is_duplicate = false
        unique_points.each do |upt|
          if pt.distance(upt) < 0.001
            is_duplicate = true
            break
          end
        end
        unique_points << pt unless is_duplicate
      end

      if unique_points.length < 3
        puts "警告: 无法创建纹理平面，点重复或共线"
        return nil
      end

      face = entities.add_face(unique_points)
      if face

        face_normal = face.normal

        if face_normal.dot(normal) < 0

          face.reverse!
        end

        face.material = material

        set_texture_to_fill_face(face, material, width, height, normal)

        return face
      end

      nil
    end

    def convert_face_to_group(parent_group, face)
      return nil unless face && parent_group

      begin

        edges = face.edges
        vertices = face.vertices

        entities = parent_group.entities
        face_group = entities.add_group

        points = vertices.map(&:position)

        new_face = face_group.entities.add_face(points)

        if new_face

          new_face.material = face.material if face.material
          new_face.back_material = face.back_material if face.back_material

          if face.material && face.material.texture
            copy_face_uv(face, new_face, false)
          end
          if face.back_material && face.back_material.texture
            copy_face_uv(face, new_face, true)
          end

          face.erase!

          return face_group
        else
          face_group.erase!
          return nil
        end
      rescue => e
        puts "将面转换为群组失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
        return nil
      end
    end

    def convert_group_to_component(group)
      return unless group

        entities = @model.active_entities

      begin
        component_def = @model.definitions.add("AutoRender_Faces_#{Time.now.to_i}")

        group_transformation = group.transformation
        group_origin = group_transformation.origin

        group.entities.each do |entity|
          if entity.is_a?(Sketchup::Face)
            points = entity.vertices.map(&:position)
            new_face = component_def.entities.add_face(points)
            if new_face
              new_face.material = entity.material if entity.material
              new_face.back_material = entity.back_material if entity.back_material

              if entity.material && entity.material.texture
                copy_face_uv(entity, new_face, false)
              end
              if entity.back_material && entity.back_material.texture
                copy_face_uv(entity, new_face, true)
              end
            end
          elsif entity.is_a?(Sketchup::Group)

            new_group = component_def.entities.add_group
            entity.entities.each do |sub_entity|
              if sub_entity.is_a?(Sketchup::Face)
                points = sub_entity.vertices.map(&:position)
                new_face = new_group.entities.add_face(points)
                if new_face
                  new_face.material = sub_entity.material if sub_entity.material
                  new_face.back_material = sub_entity.back_material if sub_entity.back_material

                  if sub_entity.material && sub_entity.material.texture
                    copy_face_uv(sub_entity, new_face, false)
                  end
                  if sub_entity.back_material && sub_entity.back_material.texture
                    copy_face_uv(sub_entity, new_face, true)
                  end
                end
              end
            end

            new_group.transformation = entity.transformation
          end
        end

        instance = entities.add_instance(component_def, group_transformation)

        group.erase!

        instance
      rescue => e
        puts "转换为组件失败，保留为组: #{e.message}"
        puts "错误详情: #{e.backtrace.first(5).join("\n")}"
        group
      end
    end

    def place_single_face_centered(selection)
      return if @rendered_images.empty?

      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]
      global_bounds = bounding_box_info[:bounding_box]

      front_item = @rendered_images.find { |item| item[:name] == 'front' }
      return unless front_item && front_item[:file_path] && File.exist?(front_item[:file_path])

      materials = @model.materials
      material = materials.add("AutoRender_front_#{Time.now.to_i}")

          load_material_texture(material, front_item[:file_path], "加载纹理失败") || return

      if local_bounds && transformation && !local_bounds.empty?

        group = create_single_face_aligned(local_bounds, transformation, material, front_item, 'front')
      else

        group = create_single_face_simple(global_bounds, material, front_item)
      end

      return unless group

      component_instance = convert_group_to_face_camera_component(group)

      if component_instance
        fix_component_material_uv(component_instance)
      end

      component_instance
    end

    def create_single_face_aligned(local_bounds, transformation, material, item, view_name)

      width = local_bounds.width
      height = local_bounds.height
      depth = local_bounds.depth

      width = [width, 999999].min
      height = [height, 999999].min
      depth = [depth, 999999].min

      if width <= 0 || height <= 0 || depth <= 0
        return nil
      end

      local_center = local_bounds.center

      entities = @model.active_entities
      group = entities.add_group

      face_config = {
        local_center: Geom::Point3d.new(0, 0, 0),  
        local_normal: Geom::Vector3d.new(0, 1, 0),
        local_up: Geom::Vector3d.new(0, 0, 1),
        face_width: width,
        face_height: depth
      }

      face = create_texture_plane_in_group(
        group,
        face_config[:local_center],
        face_config[:local_normal],
        face_config[:local_up],
        face_config[:face_width],
        face_config[:face_height],
        material,
        item
      )

      return nil unless face

      face.reverse!

      set_texture_to_fill_face(face, material, face_config[:face_width], face_config[:face_height], face_config[:local_normal])

      move_to_local_center = Geom::Transformation.translation(local_center)
      final_transformation = transformation * move_to_local_center

      group.transformation = final_transformation

      group
    end

    def create_single_face_simple(global_bounds, material, item)
      center = global_bounds.center
      min_point = global_bounds.min
      max_point = global_bounds.max

      width = global_bounds.width
      height_bb = global_bounds.height
      depth = global_bounds.depth

      entities = @model.active_entities
      group = entities.add_group

      face_width = width
      face_height = max_point.z - min_point.z

      local_position = Geom::Point3d.new(0, 0, 0)  
      normal = Geom::Vector3d.new(0, 1, 0)  
      up = Geom::Vector3d.new(0, 0, 1)

      face = create_texture_plane_in_group(
        group,
        local_position,
        normal,
        up,
        face_width,
        face_height,
        material,
        item
      )

      return nil unless face

      face.reverse!

      set_texture_to_fill_face(face, material, face_width, face_height, normal)

      translation = Geom::Transformation.translation(center)
      group.transformation = translation

      group
    end

    def place_images_centered(selection)
      return if @rendered_images.empty?

      bounding_box_info = get_selection_bounding_box_with_transform(selection)
      return if bounding_box_info.nil?

      local_bounds = bounding_box_info[:local_bounds]
      transformation = bounding_box_info[:transformation]
      global_bounds = bounding_box_info[:bounding_box]

      if local_bounds && transformation && !local_bounds.empty?

        group = create_centered_faces_group(local_bounds, transformation)
      else

        group = create_centered_faces_group_simple(global_bounds)
      end

      component_instance = nil
            if group
        component_instance = convert_group_to_component(group)
      end

      if component_instance
        fix_component_material_uv(component_instance)

        apply_back_materials_to_centered_component(component_instance)
      end

      component_instance
    end

    def create_centered_faces_group(local_bounds, transformation)

      width = local_bounds.width
      height = local_bounds.height
      depth = local_bounds.depth

      width = [width, 999999].min
      height = [height, 999999].min
      depth = [depth, 999999].min

      if width <= 0 || height <= 0 || depth <= 0
        return nil
      end

      local_center = local_bounds.center

      entities = @model.active_entities
      group = entities.add_group

      created_faces = {}

      front_item = @rendered_images.find { |item| item[:name] == 'front' }
      back_item = @rendered_images.find { |item| item[:name] == 'back' }
      left_item = @rendered_images.find { |item| item[:name] == 'left' }
      right_item = @rendered_images.find { |item| item[:name] == 'right' }
      top_item = @rendered_images.find { |item| item[:name] == 'top' }

      materials = @model.materials

      if left_item && left_item[:file_path] && File.exist?(left_item[:file_path])
        left_material = materials.add("AutoRender_left_#{Time.now.to_i}")
              load_material_texture(left_material, left_item[:file_path], "加载左视角纹理失败")

        right_material = nil
        if right_item && right_item[:file_path] && File.exist?(right_item[:file_path])
          right_material = materials.add("AutoRender_right_#{Time.now.to_i}")
            load_material_texture(right_material, right_item[:file_path], "加载右视角纹理失败")
        end

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(0, 0, 0),  
          Geom::Vector3d.new(-1, 0, 0),  
          Geom::Vector3d.new(0, 0, 1),  
          height,
          depth,
          left_material,
          left_item
        )

        if face
          face.reverse!

          face.material = left_material
          set_texture_to_fill_face(face, left_material, height, depth, Geom::Vector3d.new(-1, 0, 0))

          face_group = convert_face_to_group(group, face)

          created_faces['left'] = {
            group: face_group,
            back_material: right_material,
            back_item: right_item
          }
        end
      end

      if front_item && front_item[:file_path] && File.exist?(front_item[:file_path])
        front_material = materials.add("AutoRender_front_#{Time.now.to_i}")
          load_material_texture(front_material, front_item[:file_path], "加载前视角纹理失败")

        back_material = nil
        if back_item && back_item[:file_path] && File.exist?(back_item[:file_path])
          back_material = materials.add("AutoRender_back_#{Time.now.to_i}")
            load_material_texture(back_material, back_item[:file_path], "加载后视角纹理失败")
        end

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(0, height/2, 0),  
          Geom::Vector3d.new(0, -1, 0),  
          Geom::Vector3d.new(0, 0, 1),  
          width,
          depth,
          front_material,
          front_item
        )

        if face
          face.reverse!

          face.material = front_material
          set_texture_to_fill_face(face, front_material, width, depth, Geom::Vector3d.new(0, -1, 0))

          face_group = convert_face_to_group(group, face)

          if face_group

            bounding_box = face_group.bounds
            flip_center = bounding_box.center

            translation_to_origin = Geom::Transformation.translation(
              Geom::Vector3d.new(-flip_center.x, -flip_center.y, -flip_center.z)
            )
            y_flip = Geom::Transformation.scaling(1, -1, 1)  
            translation_back = Geom::Transformation.translation(flip_center)
            flip_transformation = translation_back * y_flip * translation_to_origin

            current_transformation = face_group.transformation
            face_group.transformation = current_transformation * flip_transformation
          end

          created_faces['front'] = {
            group: face_group,
            back_material: back_material,
            back_item: back_item
          }
        end
      end

      if top_item && top_item[:file_path] && File.exist?(top_item[:file_path])
        top_material = materials.add("AutoRender_top_#{Time.now.to_i}")
          load_material_texture(top_material, top_item[:file_path], "加载顶视角纹理失败")

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(0, 0, -depth/2),
          Geom::Vector3d.new(0, 0, -1),
          Geom::Vector3d.new(0, 1, 0),
          width,
          height,
          top_material,
          top_item
        )

        if face
          face.reverse!
          flip_texture_horizontally_front(face, top_material)
          created_faces['top'] = face
        end
      end

      if created_faces.empty?
        group.erase!
        return nil
      end

      move_to_local_center = Geom::Transformation.translation(local_center)
      final_transformation = transformation * move_to_local_center

      group.transformation = final_transformation

      group
    end

    def create_centered_faces_group_simple(global_bounds)
      center = global_bounds.center
      min_point = global_bounds.min
      max_point = global_bounds.max

      width = global_bounds.width
      height_bb = global_bounds.height
      depth = global_bounds.depth

      entities = @model.active_entities
      group = entities.add_group

      created_faces = {}

      front_item = @rendered_images.find { |item| item[:name] == 'front' }
      back_item = @rendered_images.find { |item| item[:name] == 'back' }
      left_item = @rendered_images.find { |item| item[:name] == 'left' }
      right_item = @rendered_images.find { |item| item[:name] == 'right' }
      top_item = @rendered_images.find { |item| item[:name] == 'top' }

      materials = @model.materials

      if left_item && left_item[:file_path] && File.exist?(left_item[:file_path])
        left_material = materials.add("AutoRender_left_#{Time.now.to_i}")
        begin
          left_material.texture = left_item[:file_path] if File.exist?(left_item[:file_path])
        rescue => e
          puts "加载左视角纹理失败: #{e.message}"
        end

        right_material = nil
        if right_item && right_item[:file_path] && File.exist?(right_item[:file_path])
          right_material = materials.add("AutoRender_right_#{Time.now.to_i}")
            load_material_texture(right_material, right_item[:file_path], "加载右视角纹理失败")
        end

        face_width = height_bb
        face_height = max_point.z - min_point.z

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(min_point.x - center.x - 0.01, 0, 0),  
          Geom::Vector3d.new(1, 0, 0),  
          Geom::Vector3d.new(0, 0, 1),
          face_width,
          face_height,
          left_material,
          left_item
        )

        if face
          face.reverse!
          face.material = left_material
          set_texture_to_fill_face(face, left_material, face_width, face_height, Geom::Vector3d.new(1, 0, 0))

          face_group = convert_face_to_group(group, face)

          created_faces['left'] = {
            group: face_group,
            back_material: right_material,
            back_item: right_item
          }
        end
      end

      if front_item && front_item[:file_path] && File.exist?(front_item[:file_path])
        front_material = materials.add("AutoRender_front_#{Time.now.to_i}")
          load_material_texture(front_material, front_item[:file_path], "加载前视角纹理失败")

        back_material = nil
        if back_item && back_item[:file_path] && File.exist?(back_item[:file_path])
          back_material = materials.add("AutoRender_back_#{Time.now.to_i}")
            load_material_texture(back_material, back_item[:file_path], "加载后视角纹理失败")
        end

        face_width = width
        face_height = max_point.z - min_point.z

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(0, min_point.y - center.y - 0.01, 0),  
          Geom::Vector3d.new(0, -1, 0),  
          Geom::Vector3d.new(0, 0, 1),
          face_width,
          face_height,
          front_material,
          front_item
        )

        if face
          face.reverse!
          face.material = front_material
          set_texture_to_fill_face(face, front_material, face_width, face_height, Geom::Vector3d.new(0, -1, 0))

          face_group = convert_face_to_group(group, face)

          if face_group

            bounding_box = face_group.bounds
            flip_center = bounding_box.center

            translation_to_origin = Geom::Transformation.translation(
              Geom::Vector3d.new(-flip_center.x, -flip_center.y, -flip_center.z)
            )
            y_flip = Geom::Transformation.scaling(1, -1, 1)  
            translation_back = Geom::Transformation.translation(flip_center)
            flip_transformation = translation_back * y_flip * translation_to_origin

            current_transformation = face_group.transformation
            face_group.transformation = current_transformation * flip_transformation
          end

          created_faces['front'] = {
            group: face_group,
            back_material: back_material,
            back_item: back_item
          }
        end
      end

      if top_item && top_item[:file_path] && File.exist?(top_item[:file_path])
        top_material = materials.add("AutoRender_top_#{Time.now.to_i}")
          load_material_texture(top_material, top_item[:file_path], "加载顶视角纹理失败")

        face_width = width
        face_height = height_bb

        face = create_texture_plane_in_group(
          group,
          Geom::Point3d.new(0, 0, min_point.z - center.z - 0.01),  
          Geom::Vector3d.new(0, 0, -1),  
          Geom::Vector3d.new(0, 1, 0),
          face_width,
          face_height,
          top_material,
          top_item
        )

        if face
          face.reverse!
          flip_texture_horizontally_front(face, top_material)
          created_faces['top'] = face
        end
      end

      if created_faces.empty?
        group.erase!
        return nil
      end

      translation = Geom::Transformation.translation(center)
      group.transformation = translation

      group
    end

    def apply_back_materials_to_centered_component(component_instance)
      return unless component_instance

      begin

        component_def = component_instance.definition
        return unless component_def

        left_item = @rendered_images.find { |item| item[:name] == 'left' }
        right_item = @rendered_images.find { |item| item[:name] == 'right' }
        front_item = @rendered_images.find { |item| item[:name] == 'front' }
        back_item = @rendered_images.find { |item| item[:name] == 'back' }

        materials = @model.materials
        left_material = nil
        right_material = nil
        front_material = nil
        back_material = nil

        if left_item && left_item[:file_path] && File.exist?(left_item[:file_path])
          left_material = materials.add("AutoRender_left_swap_#{Time.now.to_i}")
            load_material_texture(left_material, left_item[:file_path], "加载左视角纹理失败")
        end

        if right_item && right_item[:file_path] && File.exist?(right_item[:file_path])
          right_material = materials.add("AutoRender_right_swap_#{Time.now.to_i}")
            load_material_texture(right_material, right_item[:file_path], "加载右视角纹理失败")
        end

        if front_item && front_item[:file_path] && File.exist?(front_item[:file_path])
          front_material = materials.add("AutoRender_front_swap_#{Time.now.to_i}")
            load_material_texture(front_material, front_item[:file_path], "加载前视角纹理失败")
        end

        if back_item && back_item[:file_path] && File.exist?(back_item[:file_path])
          back_material = materials.add("AutoRender_back_swap_#{Time.now.to_i}")
            load_material_texture(back_material, back_item[:file_path], "加载后视角纹理失败")
        end

        component_def.entities.each do |entity|
          if entity.is_a?(Sketchup::Group)

            entity.entities.each do |sub_entity|
              if sub_entity.is_a?(Sketchup::Face)

                current_front_material = sub_entity.material
                current_back_material = sub_entity.back_material

                if current_front_material && current_front_material.texture
                  texture_path = current_front_material.texture.filename rescue nil
                  material_name = current_front_material.name rescue nil

                  is_left_face = false
                  is_front_face = false

                  if material_name && material_name.downcase.include?("left")
                    is_left_face = true
                  end

                  if material_name && material_name.downcase.include?("front")
                    is_front_face = true
                  end

                  if !is_left_face && !is_front_face && texture_path
                    if left_item && left_item[:file_path]
                      left_basename = File.basename(left_item[:file_path])
                      if texture_path.include?(left_basename) || texture_path.end_with?(left_basename)
                        is_left_face = true
                      end
                    end

                    if front_item && front_item[:file_path]
                      front_basename = File.basename(front_item[:file_path])
                      if texture_path.include?(front_basename) || texture_path.end_with?(front_basename)
                        is_front_face = true
                      end
                    end
                  end

                  if is_left_face && right_material && left_material
                    begin

                      sub_entity.material = right_material
                      sub_entity.back_material = left_material

                      process_face_uv_front(sub_entity, right_material, right_item)

                      process_face_uv_back(sub_entity, left_material, left_item)

                    rescue => e
                      puts "调换左视图面的材质失败: #{e.message}"
                      puts "错误详情: #{e.backtrace.first(3).join("\n")}"
                    end
                  end

                  if is_front_face && back_material && front_material
                    begin

                      sub_entity.material = back_material
                      sub_entity.back_material = front_material

                      process_face_uv_front(sub_entity, back_material, back_item)

                      process_face_uv_back(sub_entity, front_material, front_item)

                    rescue => e
                      puts "调换前视图面的材质失败: #{e.message}"
                      puts "错误详情: #{e.backtrace.first(3).join("\n")}"
                    end
                  end
                end
              end
            end
          end
        end

      rescue => e
        puts "处理组件内群组背面材质失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(5).join("\n")}"
      end
    end

    def process_face_uv_front(face, material, item)
      begin

        vertices = face.vertices
        vertex_count = vertices.length

        if vertex_count < 3
          puts "警告: 面的顶点数少于3个，跳过"
          return false
        end

        max_vertices = [vertex_count, 4].min
        ps = vertices[0, max_vertices].map(&:position)

        uv_helper = face.get_UVHelper(true)

        uvs = []
        uv_valid = true

        ps.each do |p|
          begin
            uvq = uv_helper.get_front_UVQ(p)
            if uvq.z.abs < 1e-10
              puts "警告: UV坐标z值过小，跳过此面"
              uv_valid = false
              break
            else
              uvq.x /= uvq.z
              uvq.y /= uvq.z
              uvs << Geom::Point3d.new(uvq.x, uvq.y, 1.0)
            end
          rescue => e
            puts "获取正面UV坐标失败: #{e.message}，跳过此面"
            uv_valid = false
            break
          end
        end

        return false unless uv_valid && uvs.length == ps.length

        uv_copy = ps.zip(uvs).flatten!

        need_flip_horizontal = false
        if item && item[:name]
          if item[:name] == 'back' || item[:name] == 'left'
            need_flip_horizontal = true
          end
        end

        if max_vertices == 4

          if need_flip_horizontal

            uv_copy[1] = Geom::Point3d.new(1.0, 0.0, 1.0)  
            uv_copy[3] = Geom::Point3d.new(0.0, 0.0, 1.0)  
            uv_copy[5] = Geom::Point3d.new(0.0, 1.0, 1.0)  
            uv_copy[7] = Geom::Point3d.new(1.0, 1.0, 1.0)  
          else
            uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)
            uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)
            uv_copy[5] = Geom::Point3d.new(1.0, 1.0, 1.0)
            uv_copy[7] = Geom::Point3d.new(0.0, 1.0, 1.0)
          end
        elsif max_vertices == 3

          if need_flip_horizontal

            uv_copy[1] = Geom::Point3d.new(1.0, 0.0, 1.0)  
            uv_copy[3] = Geom::Point3d.new(0.0, 0.0, 1.0)  
            uv_copy[5] = Geom::Point3d.new(0.5, 1.0, 1.0)  
          else
            uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)
            uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)
            uv_copy[5] = Geom::Point3d.new(0.5, 1.0, 1.0)
          end
        end

        face.material = material
        result = face.position_material(material, uv_copy, true)  

        return result

      rescue => e
        puts "处理面正面UV时出错: #{e.message}"
        puts "错误位置: #{e.backtrace.first(2).join("\n")}"
        return false
      end
    end

    def process_face_uv_back(face, material, item)
      begin

        vertices = face.vertices
        vertex_count = vertices.length

        if vertex_count < 3
          puts "警告: 面的顶点数少于3个，跳过"
          return false
        end

        max_vertices = [vertex_count, 4].min
        ps = vertices[0, max_vertices].map(&:position)

        uv_helper = face.get_UVHelper(true)

        uvs = []
        uv_valid = true

        ps.each do |p|
          begin
            uvq = uv_helper.get_back_UVQ(p)
            if uvq.z.abs < 1e-10
              puts "警告: UV坐标z值过小，跳过此面"
              uv_valid = false
              break
            else
              uvq.x /= uvq.z
              uvq.y /= uvq.z
              uvs << Geom::Point3d.new(uvq.x, uvq.y, 1.0)
            end
          rescue => e
            puts "获取背面UV坐标失败: #{e.message}，跳过此面"
            uv_valid = false
            break
          end
        end

        return false unless uv_valid && uvs.length == ps.length

        uv_copy = ps.zip(uvs).flatten!

        need_flip_horizontal = false
        if item && item[:name]
          if item[:name] == 'back' || item[:name] == 'left'
            need_flip_horizontal = true
          end
        end

        if max_vertices == 4

          if need_flip_horizontal

            uv_copy[1] = Geom::Point3d.new(1.0, 0.0, 1.0)  
            uv_copy[3] = Geom::Point3d.new(0.0, 0.0, 1.0)  
            uv_copy[5] = Geom::Point3d.new(0.0, 1.0, 1.0)  
            uv_copy[7] = Geom::Point3d.new(1.0, 1.0, 1.0)  
          else
            uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)
            uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)
            uv_copy[5] = Geom::Point3d.new(1.0, 1.0, 1.0)
            uv_copy[7] = Geom::Point3d.new(0.0, 1.0, 1.0)
          end
        elsif max_vertices == 3

          if need_flip_horizontal

            uv_copy[1] = Geom::Point3d.new(1.0, 0.0, 1.0)  
            uv_copy[3] = Geom::Point3d.new(0.0, 0.0, 1.0)  
            uv_copy[5] = Geom::Point3d.new(0.5, 1.0, 1.0)  
          else
            uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)
            uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)
            uv_copy[5] = Geom::Point3d.new(0.5, 1.0, 1.0)
          end
        end

        face.back_material = material
        result = face.position_material(material, uv_copy, false)  

        return result

      rescue => e
        puts "处理面背面UV时出错: #{e.message}"
        puts "错误位置: #{e.backtrace.first(2).join("\n")}"
        return false
      end
    end

    def set_uv_back_material(face, material, item)
      return unless material && face && item

      unless material.texture
        if item[:file_path] && File.exist?(item[:file_path])
          begin
            material.texture = item[:file_path]
          rescue => e
            puts "警告: 材质没有纹理且无法加载，跳过UV设置: #{e.message}"
            return
          end
        else
          puts "警告: 材质没有纹理且文件不存在，跳过UV设置"
          return
        end
      end

      begin

        vertices = face.vertices
        return if vertices.length < 3

        max_vertices = [vertices.length, 4].min
        ps = vertices[0, max_vertices].map(&:position)

        view_config = item[:view_config]
        unless view_config
          puts "警告: item没有view_config，使用默认UV映射"

          uv_helper = face.get_UVHelper(true)
          uvs = ps.map do |p|
            uvq = uv_helper.get_back_UVQ(p)
            uvq.x /= uvq.z
            uvq.y /= uvq.z
            Geom::Point3d.new(uvq.x, uvq.y, 1.0)
          end
          uv_copy = ps.zip(uvs).flatten!
          face.position_material(material, uv_copy, true)
          return
        end

        face_normal = face.normal
        back_normal = face_normal.clone
        back_normal.length = -back_normal.length  

        case item[:name]
        when 'right'

          set_uv_back_material_by_view(face, material, item, back_normal)
        when 'back'

          set_uv_back_material_by_view(face, material, item, back_normal)
        else

          set_uv_back_material_by_view(face, material, item, back_normal)
        end

      rescue => e
        puts "设置背面UV材质失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def set_uv_back_material_by_view(face, material, item, back_normal)
      begin

        vertices = face.vertices
        return if vertices.length < 3

        max_vertices = [vertices.length, 4].min
        ps = vertices[0, max_vertices].map(&:position)

        view_config = item[:view_config]
        return unless view_config

        view_width = view_config[:view_width].to_f
        view_height = view_config[:view_height].to_f

        begin
          if material.texture && material.texture.respond_to?(:size=)
            material.texture.size = [view_width, view_height]
          end
        rescue => e
          puts "设置纹理尺寸失败: #{e.message}"
        end

        face_bbox = face.bounds
        face_min = face_bbox.min
        face_max = face_bbox.max

        case item[:name]
        when 'right'

          bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
          bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
          top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_max.z))
          top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))

          u_offset = 0.1
          uv_mapping = [
            bottom_left.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
            bottom_right.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
            top_right.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0),
            top_left.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0)
          ]
          face.position_material(material, uv_mapping, true)

        when 'back'

          bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
          bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
          top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))
          top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_max.z))

          u_offset = 0.1
          uv_mapping = [
            bottom_left.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
            bottom_right.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
            top_right.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0),
            top_left.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0)
          ]
          face.position_material(material, uv_mapping, true)

        else

          uv_helper = face.get_UVHelper(true)
          uvs = ps.map do |p|
            uvq = uv_helper.get_back_UVQ(p)
            uvq.x /= uvq.z
            uvq.y /= uvq.z
            Geom::Point3d.new(uvq.x, uvq.y, 1.0)
          end

          uv_copy = ps.zip(uvs).flatten!
          face.position_material(material, uv_copy, true)
        end

      rescue => e
        puts "根据视角设置背面UV失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def convert_group_to_face_camera_component(group)
      return unless group

      entities = @model.active_entities

      begin
        component_def = @model.definitions.add("AutoRender_FaceCamera_#{Time.now.to_i}")

                group_transformation = group.transformation
                group_origin = group_transformation.origin

                group.entities.each do |entity|
                  if entity.is_a?(Sketchup::Face)
                    points = entity.vertices.map(&:position)
                    new_face = component_def.entities.add_face(points)
                    if new_face
                      new_face.material = entity.material if entity.material
                      new_face.back_material = entity.back_material if entity.back_material

              if entity.material && entity.material.texture
                copy_face_uv(entity, new_face, false)
              end
              if entity.back_material && entity.back_material.texture
                copy_face_uv(entity, new_face, true)
              end
                    end
                  end
                end

        begin
          component_def.behavior.always_face_camera = true
        rescue => e
          puts "设置总是面向相机失败: #{e.message}"
        end

        instance = entities.add_instance(component_def, group_transformation)

                group.erase!

        instance
      rescue => e
        puts "转换为组件失败，保留为组: #{e.message}"
        puts "错误详情: #{e.backtrace.first(5).join("\n")}"
        group
              end
            end

    def copy_face_uv(source_face, target_face, is_back)
      begin
        uv_helper = source_face.get_UVHelper(true)
        vertices = source_face.vertices
        return if vertices.length < 3

        ps = vertices[0, [vertices.length, 4].min].map(&:position)
        uvs = ps.map do |p|
          uvq = is_back ? uv_helper.get_back_UVQ(p) : uv_helper.get_front_UVQ(p)
          uvq.x /= uvq.z
          uvq.y /= uvq.z
          uvq.z = 1
          uvq
        end

        target_vertices = target_face.vertices[0, [target_face.vertices.length, 4].min]
        target_ps = target_vertices.map(&:position)

        uv_copy = target_ps.zip(uvs).flatten!
        material = is_back ? target_face.back_material : target_face.material
        target_face.position_material(material, uv_copy, is_back)
      rescue => e
        puts "复制UV坐标失败: #{e.message}"
      end
    end

    def adjust_texture_uv(material, item)
      return unless material.texture && item[:view_config]

      view_config = item[:view_config]
      view_name = item[:name]

      min_point = view_config[:min_point]
      max_point = view_config[:max_point]
      view_width = view_config[:view_width].to_f
      view_height = view_config[:view_height].to_f

      image_size = @image_size.to_f

      if view_name == 'front' || view_name == 'right'

        model_width = view_width
        model_height = view_height

        camera_height = model_height * 1.25
        model_width_ratio = model_width / camera_height
        model_height_ratio = model_height / camera_height

        u_offset = (1.0 - model_width_ratio) / 2.0

        v_offset = 0.3

        begin

          if material.texture.respond_to?(:position=)

            material.texture.position = [u_offset, v_offset]
          end
        rescue => e
          puts "无法调整UV坐标: #{e.message}"
        end
      elsif view_name == 'top'

        model_width = view_width
        model_height = view_height

        camera_height = [model_width, model_height].max * 1.25
        model_width_ratio = model_width / camera_height
        model_height_ratio = model_height / camera_height

        u_offset = (1.0 - model_width_ratio) / 2.0
        v_offset = (1.0 - model_height_ratio) / 2.0

        begin
          if material.texture.respond_to?(:position=)
            material.texture.position = [u_offset, v_offset]
          end
        rescue => e
          puts "无法调整UV坐标: #{e.message}"
        end
      end
    end

    def create_texture_plane_shared(center, normal, width, height, front_material, back_material, front_item, back_item)

      width = width.to_f
      height = height.to_f

      if width <= 0 || height <= 0
        puts "警告: 纹理平面尺寸无效，跳过创建"
        return nil
      end

      entities = @model.active_entities

      if normal == Geom::Vector3d.new(0, 1, 0)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(1, 0, 0)

        right = Geom::Vector3d.new(0, -1, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      else

        fixed_up = Geom::Vector3d.new(0, 0, 1)
        cross_product = normal % fixed_up
        if cross_product.is_a?(Geom::Vector3d) && cross_product.length < 0.1
          fixed_up = Geom::Vector3d.new(1, 0, 0)
        end

        right = normal * fixed_up
        unless right.is_a?(Geom::Vector3d)
          right = Geom::Vector3d.new(right)
        end

        if right.length < 0.001
          fixed_up = Geom::Vector3d.new(1, 0, 0) if fixed_up == Geom::Vector3d.new(0, 0, 1)
          fixed_up = Geom::Vector3d.new(0, 1, 0) if fixed_up == Geom::Vector3d.new(1, 0, 0)
          right = normal * fixed_up
          unless right.is_a?(Geom::Vector3d)
            right = Geom::Vector3d.new(right)
          end
        end

        right.normalize!

        up = right * normal
        unless up.is_a?(Geom::Vector3d)
          up = Geom::Vector3d.new(up)
        end

        if up.length < 0.001
          up = Geom::Vector3d.new(-right.y, right.x, 0)
          if up.length < 0.001
            up = Geom::Vector3d.new(0, -right.z, right.y)
          end
        end

        up.normalize!
      end

      unless center.is_a?(Geom::Point3d)
        center = Geom::Point3d.new(center)
      end

      half_width = width / 2.0
      half_height = height / 2.0

      right_scaled_x = right.x * half_width
      right_scaled_y = right.y * half_width
      right_scaled_z = right.z * half_width

      up_scaled_x = up.x * half_height
      up_scaled_y = up.y * half_height
      up_scaled_z = up.z * half_height

      p1 = Geom::Point3d.new(
        center.x - right_scaled_x - up_scaled_x,
        center.y - right_scaled_y - up_scaled_y,
        center.z - right_scaled_z - up_scaled_z
      )
      p2 = Geom::Point3d.new(
        center.x + right_scaled_x - up_scaled_x,
        center.y + right_scaled_y - up_scaled_y,
        center.z + right_scaled_z - up_scaled_z
      )
      p3 = Geom::Point3d.new(
        center.x + right_scaled_x + up_scaled_x,
        center.y + right_scaled_y + up_scaled_y,
        center.z + right_scaled_z + up_scaled_z
      )
      p4 = Geom::Point3d.new(
        center.x - right_scaled_x + up_scaled_x,
        center.y - right_scaled_y + up_scaled_y,
        center.z - right_scaled_z + up_scaled_z
      )

      points = [p1, p2, p3, p4]
      unique_points = []
      points.each do |pt|
        is_duplicate = false
        unique_points.each do |upt|
          if pt.distance(upt) < 0.001
            is_duplicate = true
            break
          end
        end
        unique_points << pt unless is_duplicate
      end

      if unique_points.length < 3
        puts "警告: 无法创建纹理平面，点重复或共线"
        return nil
      end

      points = unique_points.length == 3 ? unique_points : unique_points

      face = entities.add_face(points)
      if face

        face_normal = face.normal
        if face_normal.dot(normal) < 0.5  
          face.reverse!
        end

        face.material = front_material
        face.back_material = back_material

        if normal == Geom::Vector3d.new(0, 1, 0)

          set_texture_to_fill_face(face, front_material, width, height, normal)
        elsif normal == Geom::Vector3d.new(1, 0, 0)

          set_texture_to_fill_face(face, front_material, width, height, normal)
        end

        if normal == Geom::Vector3d.new(0, 1, 0)

          set_texture_to_fill_face_back(face, back_material, width, height, Geom::Vector3d.new(0, -1, 0))

        elsif normal == Geom::Vector3d.new(1, 0, 0)

          set_texture_to_fill_face_back(face, back_material, width, height, Geom::Vector3d.new(-1, 0, 0))

        end

        return face
      end

      nil
    end

    def create_texture_plane(center, normal, width, height, material, item = nil)

      width = width.to_f
      height = height.to_f

      if width <= 0 || height <= 0
        puts "警告: 纹理平面尺寸无效，跳过创建"
        return
      end

      entities = @model.active_entities

      if normal == Geom::Vector3d.new(0, 1, 0)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(0, -1, 0)

        right = Geom::Vector3d.new(-1, 0, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(0, 0, -1)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, 1, 0)
      elsif normal == Geom::Vector3d.new(0, 0, 1)

        right = Geom::Vector3d.new(1, 0, 0)
        up = Geom::Vector3d.new(0, -1, 0)
      elsif normal == Geom::Vector3d.new(-1, 0, 0)

        right = Geom::Vector3d.new(0, 1, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      elsif normal == Geom::Vector3d.new(1, 0, 0)

        right = Geom::Vector3d.new(0, -1, 0)
        up = Geom::Vector3d.new(0, 0, 1)
      else

        fixed_up = Geom::Vector3d.new(0, 0, 1)
        cross_product = normal % fixed_up
        if cross_product.is_a?(Geom::Vector3d) && cross_product.length < 0.1
          fixed_up = Geom::Vector3d.new(1, 0, 0)
        end

        right = normal * fixed_up
        unless right.is_a?(Geom::Vector3d)
          right = Geom::Vector3d.new(right)
        end

        if right.length < 0.001
          fixed_up = Geom::Vector3d.new(1, 0, 0) if fixed_up == Geom::Vector3d.new(0, 0, 1)
          fixed_up = Geom::Vector3d.new(0, 1, 0) if fixed_up == Geom::Vector3d.new(1, 0, 0)
          right = normal * fixed_up
          unless right.is_a?(Geom::Vector3d)
            right = Geom::Vector3d.new(right)
          end
        end

        right.normalize!

        up = right * normal
        unless up.is_a?(Geom::Vector3d)
          up = Geom::Vector3d.new(up)
        end

        if up.length < 0.001
          up = Geom::Vector3d.new(-right.y, right.x, 0)
          if up.length < 0.001
            up = Geom::Vector3d.new(0, -right.z, right.y)
          end
        end

        up.normalize!
      end

      unless center.is_a?(Geom::Point3d)
        center = Geom::Point3d.new(center)
      end

      half_width = width / 2.0
      half_height = height / 2.0

      right_scaled_x = right.x * half_width
      right_scaled_y = right.y * half_width
      right_scaled_z = right.z * half_width

      up_scaled_x = up.x * half_height
      up_scaled_y = up.y * half_height
      up_scaled_z = up.z * half_height

      p1 = Geom::Point3d.new(
        center.x - right_scaled_x - up_scaled_x,
        center.y - right_scaled_y - up_scaled_y,
        center.z - right_scaled_z - up_scaled_z
      )
      p2 = Geom::Point3d.new(
        center.x + right_scaled_x - up_scaled_x,
        center.y + right_scaled_y - up_scaled_y,
        center.z + right_scaled_z - up_scaled_z
      )
      p3 = Geom::Point3d.new(
        center.x + right_scaled_x + up_scaled_x,
        center.y + right_scaled_y + up_scaled_y,
        center.z + right_scaled_z + up_scaled_z
      )
      p4 = Geom::Point3d.new(
        center.x - right_scaled_x + up_scaled_x,
        center.y - right_scaled_y + up_scaled_y,
        center.z - right_scaled_z + up_scaled_z
      )

      points = [p1, p2, p3, p4]
      unique_points = []
      points.each do |pt|
        is_duplicate = false
        unique_points.each do |upt|
          if pt.distance(upt) < 0.001
            is_duplicate = true
            break
          end
        end
        unique_points << pt unless is_duplicate
      end

      if unique_points.length < 3
        puts "警告: 无法创建纹理平面，点重复或共线"
        return
      end

      if unique_points.length == 3
        points = unique_points
      else
        points = unique_points
      end

      face = entities.add_face(points)
      if face

        face_normal = face.normal

        if face_normal.dot(normal) < 0
          face.reverse!
        end

        face.material = material

        set_texture_to_fill_face(face, material, width, height, normal)

        return face
      else
      end

      nil
    end

    def set_texture_to_fill_face_back(face, material, width, height, normal)

      set_uv_point_mapping_back(face, material, width, height, normal)

      adjust_uv_after_mapping_back(face, material)
    end

    def set_texture_to_fill_face(face, material, width, height, normal)

      set_uv_point_mapping(face, material, width, height, normal)

      adjust_uv_after_mapping(face, material)
    end

    def flip_texture_horizontally_front(face, material)
      begin

        return unless material && material.texture

        uv_helper = face.get_UVHelper(true)
        ps = face.vertices[0, 4].map(&:position)

        uvs = ps.map do |p|
          uvq = uv_helper.get_front_UVQ(p)
          uvq.x /= uvq.z
          uvq.y /= uvq.z
          uvq.z = 1
          uvq
        end

        uvs_flipped = uvs.map do |uvq|
          Geom::Point3d.new(1.0 - uvq.x, uvq.y, uvq.z)
        end

        pts = face.vertices[0, 4].map(&:position)
        uv_copy = pts.zip(uvs_flipped).flatten!
        face.position_material(material, uv_copy, false)

      rescue => e
        puts "左右翻转正面材质失败: #{e.message}"
      end
    end

    def flip_texture_horizontally_back(face, material)
      begin

        return unless material && material.texture

        uv_helper = face.get_UVHelper(true)
        ps = face.vertices[0, 4].map(&:position)

        uvs = ps.map do |p|
          uvq = uv_helper.get_back_UVQ(p)
          uvq.x /= uvq.z
          uvq.y /= uvq.z
          uvq.z = 1
          uvq
        end

        uvs_flipped = uvs.map do |uvq|
          Geom::Point3d.new(1.0 - uvq.x, uvq.y, uvq.z)
        end

        pts = face.vertices[0, 4].map(&:position)
        uv_copy = pts.zip(uvs_flipped).flatten!
        face.position_material(material, uv_copy, true)

      rescue => e
        puts "左右翻转背面材质失败: #{e.message}"
      end
    end

    def adjust_uv_after_mapping_back(face, material)
      begin

        return unless material && material.texture

        uv_helper = face.get_UVHelper(true)
        ps = face.vertices[0, 4].map(&:position)

        uvs = ps.map do |p|
          uvq = uv_helper.get_back_UVQ(p)
          uvq.x /= uvq.z
          uvq.y /= uvq.z
          uvq.z = 1
          uvq
        end

        uvs_rounded = uvs.map do |uvq|
          Geom::Point3d.new(uvq.x.round, uvq.y.round, uvq.z.round)
        end

        pts = face.vertices[0, 4].map(&:position)
        uv_copy = pts.zip(uvs_rounded).flatten!
        face.position_material(material, uv_copy, true)

      rescue => e
        puts "背面UV调整失败: #{e.message}"
      end
    end

    def adjust_uv_after_mapping(face, material)
      begin

        return unless material && material.texture

        uv_helper = face.get_UVHelper(true)
        ps = face.vertices[0, 4].map(&:position)

        uvs = ps.map do |p|
          uvq = uv_helper.get_front_UVQ(p)
          uvq.x /= uvq.z
          uvq.y /= uvq.z
          uvq.z = 1
          uvq
        end

        uvs_rounded = uvs.map do |uvq|
          Geom::Point3d.new(uvq.x.round, uvq.y.round, uvq.z.round)
        end

        pts = face.vertices[0, 4].map(&:position)
        uv_copy = pts.zip(uvs_rounded).flatten!
        face.position_material(material, uv_copy, false)

      rescue => e
        puts "UV调整失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def set_uv_point_mapping(face, material, width, height, normal)
      begin

        texture_size_set = false
        begin
          if material.texture && material.texture.respond_to?(:size=)
            material.texture.size = [width, height]
            texture_size_set = true
          end
        rescue => e
          puts "设置纹理尺寸失败: #{e.message}"
        end

        if face.respond_to?(:position_material)
          vertices = face.vertices

          if vertices.length >= 4

            v1 = vertices[0].position
            v2 = vertices[1].position
            v3 = vertices[2].position
            v4 = vertices[3].position

            face_bbox = face.bounds
            face_min = face_bbox.min
            face_max = face_bbox.max

            if normal == Geom::Vector3d.new(0, 1, 0)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))

              u_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, false)

            elsif normal == Geom::Vector3d.new(0, 0, -1)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_max.y, face_min.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))

              u_offset = 0.1
              v_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0 + v_offset, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0 + v_offset, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0 + v_offset, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0 + v_offset, 0)
              ]
              face.position_material(material, uv_mapping, false)

            elsif normal == Geom::Vector3d.new(-1, 0, 0)

              u_offset = 0.1

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))

              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, false)

            else

              face.position_material(material, [
                v1, Geom::Point3d.new(0.0, 0.0, 0),
                v2, Geom::Point3d.new(1.0, 0.0, 0),
                v3, Geom::Point3d.new(1.0, 1.0, 0),
                v4, Geom::Point3d.new(0.0, 1.0, 0)
              ], false)
            end

          elsif vertices.length >= 3

            v1 = vertices[0].position
            v2 = vertices[1].position
            v3 = vertices[2].position

            face.position_material(material, [
              v1, Geom::Point3d.new(0.0, 0.0, 0),
              v2, Geom::Point3d.new(1.0, 0.0, 0),
              v3, Geom::Point3d.new(0.5, 1.0, 0)
            ], false)

          end
        end
      rescue => e
        puts "点对点UV映射失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def set_uv_point_mapping_back(face, material, width, height, normal)
      begin

        begin
          if material.texture && material.texture.respond_to?(:size=)
            material.texture.size = [width, height]
          end
        rescue => e
          puts "设置纹理尺寸失败: #{e.message}"
        end

        if face.respond_to?(:position_material)
          vertices = face.vertices

          if vertices.length >= 4

            v1 = vertices[0].position
            v2 = vertices[1].position
            v3 = vertices[2].position
            v4 = vertices[3].position

            face_bbox = face.bounds
            face_min = face_bbox.min
            face_max = face_bbox.max

            if normal == Geom::Vector3d.new(0, 1, 0)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))
              u_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, true)

            elsif normal == Geom::Vector3d.new(0, -1, 0)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_max.z))
              u_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, true)

            elsif normal == Geom::Vector3d.new(0, 0, -1)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_max.y, face_min.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
              u_offset = 0.1
              v_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0 + v_offset, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0 + v_offset, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0 + v_offset, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0 + v_offset, 0)
              ]
              face.position_material(material, uv_mapping, true)

            elsif normal == Geom::Vector3d.new(0, 0, 1)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_max.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_max.x, face_min.y, face_min.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              u_offset = 0.1
              v_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0 + v_offset, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0 + v_offset, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0 + v_offset, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0 + v_offset, 0)
              ]
              face.position_material(material, uv_mapping, true)

            elsif normal == Geom::Vector3d.new(-1, 0, 0)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))
              u_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, true)

            elsif normal == Geom::Vector3d.new(1, 0, 0)

              bottom_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_min.z))
              bottom_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_min.z))
              top_right = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_min.y, face_max.z))
              top_left = find_closest_vertex(vertices, Geom::Point3d.new(face_min.x, face_max.y, face_max.z))
              u_offset = 0.1
              uv_mapping = [
                bottom_left.position, Geom::Point3d.new(0.0 + u_offset, 0.0, 0),
                bottom_right.position, Geom::Point3d.new(1.0 + u_offset, 0.0, 0),
                top_right.position, Geom::Point3d.new(1.0 + u_offset, 1.0, 0),
                top_left.position, Geom::Point3d.new(0.0 + u_offset, 1.0, 0)
              ]
              face.position_material(material, uv_mapping, true)

            else

              face.position_material(material, [
                v1, Geom::Point3d.new(0.0, 0.0, 0),
                v2, Geom::Point3d.new(1.0, 0.0, 0),
                v3, Geom::Point3d.new(1.0, 1.0, 0),
                v4, Geom::Point3d.new(0.0, 1.0, 0)
              ], true)
            end

          elsif vertices.length >= 3

            v1 = vertices[0].position
            v2 = vertices[1].position
            v3 = vertices[2].position

            face.position_material(material, [
              v1, Geom::Point3d.new(0.0, 0.0, 0),
              v2, Geom::Point3d.new(1.0, 0.0, 0),
              v3, Geom::Point3d.new(0.5, 1.0, 0)
            ], true)

          end
        end
      rescue => e
        puts "背面点对点UV映射失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def find_closest_vertex(vertices, target_point)
      closest = vertices[0]
      min_distance = closest.position.distance(target_point)

      vertices.each do |vertex|
        distance = vertex.position.distance(target_point)
        if distance < min_distance
          min_distance = distance
          closest = vertex
        end
      end

      closest
    end

    def restore_original_state
      begin

        @original_layers.each do |layer, visible|
          layer.visible = visible
        end

        if @original_rendering_options && !@original_rendering_options.empty?
          rendering_options = @model.rendering_options

          begin
            if @original_rendering_options[:background_color]
              rendering_options['BackgroundColor'] = @original_rendering_options[:background_color]
            end
          rescue
            begin
              if @original_rendering_options[:background_color]
                @view.background_color = @original_rendering_options[:background_color]
              end
            rescue

            end
          end

          begin
            if @original_rendering_options[:display_sky] != nil
              rendering_options['DisplaySky'] = @original_rendering_options[:display_sky]
            end
          rescue

          end

          begin
            if @original_rendering_options[:sky_color]
              rendering_options['SkyColor'] = @original_rendering_options[:sky_color]
            end
          rescue

          end

          begin
            if @original_rendering_options[:display_ground] != nil
              rendering_options['DisplayGround'] = @original_rendering_options[:display_ground]
            end
          rescue

          end
        end

        if @original_camera_perspective != nil
          @view.camera.perspective = @original_camera_perspective
        end

        begin

          @view.camera.aspect_ratio = 0.0
        rescue => e
          puts "清除相机纵横比失败: #{e.message}"
        end

        restore_entities_visibility(@model.active_entities)

        @view.refresh

        @model.commit_operation
      rescue => e
        @model.abort_operation
        raise e
      end
    end

    def restore_entities_visibility(entities)
      entities.each do |entity|

        next if entity.is_a?(Sketchup::Edge)

        if entity.respond_to?(:visible=)
          entity.visible = true
        end
        if entity.is_a?(Sketchup::Group)
          restore_entities_visibility(entity.entities)
        elsif entity.is_a?(Sketchup::ComponentInstance)

          restore_entities_visibility(entity.definition.entities)
        end
      end
    end

    def apply_transparent_back_material_to_component(component_instance)
      return unless component_instance

      begin

        transparent_material = get_or_create_transparent_material

        if transparent_material.nil?
          puts "无法创建透明材质，跳过应用透明背面材质"
          return
        end

        processed_count = process_entity_faces(component_instance, transparent_material)

        puts "已为 #{processed_count} 个面的背面应用透明材质"

        @view.refresh
      rescue => e
        puts "应用透明背面材质失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end

    def get_or_create_transparent_material
      materials = @model.materials
      material_name = 'AutoRender_Transparent'

      existing_material = materials[material_name]
      if existing_material
        return existing_material
      end

      begin
        transparent_material = materials.add(material_name)

        transparent_material.color = Sketchup::Color.new(255, 255, 255, 0)

        if transparent_material.respond_to?(:alpha=)
          transparent_material.alpha = 0.0
        end

        return transparent_material
      rescue => e
        puts "创建透明材质失败: #{e.message}"
        return nil
      end
    end

    def process_entity_faces(entity, transparent_material)
      count = 0

      begin

        entities = nil
        if entity.is_a?(Sketchup::ComponentInstance)
          entities = entity.definition.entities
        elsif entity.is_a?(Sketchup::Group)
          entities = entity.entities
        end

        return 0 unless entities

        entities.each do |sub_entity|
          if sub_entity.is_a?(Sketchup::Face)
            sub_entity.back_material = transparent_material
            count += 1
          elsif sub_entity.is_a?(Sketchup::ComponentInstance) || sub_entity.is_a?(Sketchup::Group)

            count += process_entity_faces(sub_entity, transparent_material)
          end
        end
      rescue => e
        puts "处理实体失败: #{e.message}"
      end

      return count
    end

    def fix_component_material_uv(component_instance)
      return unless component_instance

      begin

        entities = nil
        if component_instance.is_a?(Sketchup::ComponentInstance)
          entities = component_instance.definition.entities
        elsif component_instance.is_a?(Sketchup::Group)
          entities = component_instance.entities
        end

        return unless entities

        faces = []
        entities.each do |e|
          if e.is_a?(Sketchup::Face)
            faces << e
          end
        end

        if faces.empty?
          puts "组件中没有找到面，跳过UV修复"
          return
        end

        max_faces = [faces.length, 20].min
        processed_count = 0

        faces[0, max_faces].each do |f|
          begin

            mat = f.material
            next unless mat && mat.texture

            vertices = f.vertices
            vertex_count = vertices.length

            if vertex_count < 3
              puts "警告: 面的顶点数少于3个，跳过"
              next
            end

            max_vertices = [vertex_count, 4].min
            ps = vertices[0, max_vertices].map(&:position)

            uv_helper = f.get_UVHelper(true)

            uvs = []
            uv_valid = true

            ps.each do |p|
              begin
                uvq = uv_helper.get_front_UVQ(p)

                if uvq.z.abs < 1e-10
                  puts "警告: UV坐标z值过小，跳过此面"
                  uv_valid = false
                  break
                else
                  uvq.x /= uvq.z
                  uvq.y /= uvq.z
                  uvs << Geom::Point3d.new(uvq.x, uvq.y, 1.0)
                end
              rescue => e
                puts "获取UV坐标失败: #{e.message}，跳过此面"
                uv_valid = false
                break
              end
            end

            next unless uv_valid && uvs.length == ps.length

            if uvs.length > 1
              first_uv = uvs[0]
              all_same = uvs.all? { |uv| (uv.x - first_uv.x).abs < 1e-6 && (uv.y - first_uv.y).abs < 1e-6 }
              if all_same
                puts "警告: 所有UV坐标相同，无法计算有效矩阵，跳过此面"
                next
              end
            end

            if max_vertices >= 3
              v1 = ps[0]
              v2 = ps[1]
              v3 = ps[2]
              vec1 = v2 - v1
              vec2 = v3 - v1
              cross = vec1 * vec2
              if cross.length < 1e-6
                puts "警告: 面的前三个点共线，无法计算有效矩阵，跳过此面"
                next
              end
            end

            uv_copy = ps.zip(uvs).flatten!

            min_length = max_vertices * 2
            if uv_copy.length < min_length
              puts "警告: UV数组长度不足 (#{uv_copy.length} < #{min_length})，跳过此面"
              next
            end

            valid = true
            uv_copy.each do |item|
              unless item.is_a?(Geom::Point3d)
                valid = false
                puts "警告: UV数组中包含非Point3d元素: #{item.class}，跳过此面"
                break
              end
            end

            next unless valid

            original_uv_copy = uv_copy.dup

            [1, 3, 5, 7].each do |idx|
              if idx < uv_copy.length && uv_copy[idx].is_a?(Geom::Point3d)
                uv = uv_copy[idx]
                uv_copy[idx] = Geom::Point3d.new(uv.x.round, uv.y.round, 1.0)
              end
            end

            uv_coords_rounded = []
            (1...uv_copy.length).step(2) do |idx|
              if uv_copy[idx].is_a?(Geom::Point3d)
                uv_coords_rounded << uv_copy[idx]
              end
            end

            if uv_coords_rounded.length > 1
              first_uv = uv_coords_rounded[0]
              all_same_after_round = uv_coords_rounded.all? { |uv| (uv.x - first_uv.x).abs < 1e-6 && (uv.y - first_uv.y).abs < 1e-6 }
              if all_same_after_round
                puts "警告: 整数化后所有UV坐标相同，使用原始UV坐标"
                uv_copy = original_uv_copy
              end
            end

            if max_vertices == 4

              uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)  
              uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)  
              uv_copy[5] = Geom::Point3d.new(1.0, 1.0, 1.0)  
              uv_copy[7] = Geom::Point3d.new(0.0, 1.0, 1.0)  
            elsif max_vertices == 3

              uv_copy[1] = Geom::Point3d.new(0.0, 0.0, 1.0)   
              uv_copy[3] = Geom::Point3d.new(1.0, 0.0, 1.0)   
              uv_copy[5] = Geom::Point3d.new(0.5, 1.0, 1.0)   
            end

            success = false
            begin
              f.material = mat

              result = f.position_material(f.material, uv_copy, true)
              if result
                processed_count += 1
                success = true
              else
                puts "设置UV坐标失败，尝试使用原始UV坐标"
              end
            rescue => e
              puts "设置UV坐标出错: #{e.message}，尝试使用原始UV坐标"
            end

            unless success
              begin
                result = f.position_material(f.material, original_uv_copy, true)
                if result
                  processed_count += 1
                  success = true
                  puts "使用原始UV坐标成功"
                else
                  puts "原始UV坐标也设置失败"
                end
              rescue => e2
                puts "原始UV坐标也出错: #{e2.message}"
              end
            end

            unless success
              begin
                f.material = mat
                puts "已设置材质，但UV坐标未正确设置"
              rescue => e3
                puts "设置材质也失败: #{e3.message}"
              end
            end

          rescue => e

            puts "处理面时出错: #{e.message}"
            puts "错误位置: #{e.backtrace.first(2).join("\n")}"
            next
          end
        end

      rescue => e
        puts "修复组件材质UV失败: #{e.message}"
        puts "错误详情: #{e.backtrace.first(3).join("\n")}"
      end
    end
  end

  def self.move_local_axis_to_bottom

    model = Sketchup.active_model
    selection = model.selection

    if selection.count != 1 || !([Sketchup::ComponentInstance, Sketchup::Group].include?(selection.first.class))
      UI.messagebox("请选中一个组件或群组后再运行！")
      return
    end
    entity = selection.first

    bb = entity.bounds
    unless bb.valid?
      UI.messagebox("选中的对象无有效边界框！")
      return
    end

    bottom_center_world = Geom::Point3d.new(
      (bb.min.x + bb.max.x) / 2.0,  
      (bb.min.y + bb.max.y) / 2.0,  
      bb.min.z                      
    )

    model.start_operation("移动局部坐标轴到底部", true)

    begin
      if entity.is_a?(Sketchup::ComponentInstance)

        instance = entity
        definition = instance.definition

        transform_to_instance = instance.transformation.inverse
        bottom_center_instance = bottom_center_world.transform(transform_to_instance)

        offset = bottom_center_instance.vector_to(Geom::Point3d.new(0, 0, 0))

        transform_def = Geom::Transformation.translation(offset)
        definition.entities.transform_entities(transform_def, definition.entities.to_a)

        reverse_offset = offset.reverse 
        transform_instance = Geom::Transformation.translation(reverse_offset)
        instance.transformation = instance.transformation * transform_instance

      elsif entity.is_a?(Sketchup::Group)

        group = entity
        old_transform = group.transformation.dup

        new_transform = Geom::Transformation.new(
          old_transform.xaxis,   
          old_transform.yaxis,   
          old_transform.zaxis,   
          bottom_center_world    
        )

        group.transformation = new_transform
      end

      model.commit_operation
      UI.messagebox("局部坐标轴已成功移到组件/群组底部！")

    rescue => e

      model.abort_operation
      UI.messagebox("执行失败：#{e.message}\n错误详情：#{e.backtrace.first}")
    end
  end

  module VirtualBoxTool

    VERSION = '1.0.0' unless defined?(VERSION)

    class VirtualBoxTool
      def initialize
        @model = Sketchup.active_model
        @view = @model.active_view
        @selection = @model.selection
        @virtual_box_group = nil
        @selected_entity = nil
        @highlighted_face = nil
        @faces = []  
        @bottom_face = nil  
        @original_camera = nil
        @original_entity_transform = nil  
        @entity_restored = false  
        @main_operation_started = false  
        @original_bounds_world = nil  
      end

      def create_virtual_box

        if @selection.empty?
          UI.messagebox("请先选择一个模型！", MB_OK)
          return false
        end

        @selected_entity = @selection.first

        unless @selected_entity.is_a?(Sketchup::Group) || @selected_entity.is_a?(Sketchup::ComponentInstance)
          UI.messagebox("请选择一个组或组件！", MB_OK)
          return false
        end

        transformation = @selected_entity.transformation

        if @selected_entity.is_a?(Sketchup::Group)
          local_bounds = nil
          @selected_entity.entities.each do |ent|
            if ent.respond_to?(:bounds)
              ent_bounds = ent.bounds
              if local_bounds.nil?
                local_bounds = ent_bounds
              else
                local_bounds.add(ent_bounds)
              end
            end
          end
        else
          local_bounds = @selected_entity.definition.bounds
        end

        if local_bounds.nil? || local_bounds.empty?
          UI.messagebox("无法获取模型的边界框！", MB_OK)
          return false
        end

        width = local_bounds.width
        height = local_bounds.height
        depth = local_bounds.depth

        min_dimension = 100.0.mm
        width = [width, min_dimension].max
        height = [height, min_dimension].max
        depth = [depth, min_dimension].max

        offset_ratio = 0.0001  
        min_offset = 1.0.mm  

        width_offset = [width * offset_ratio, min_offset].max
        height_offset = [height * offset_ratio, min_offset].max
        depth_offset = [depth * offset_ratio, min_offset].max

        virtual_width = width + width_offset * 2
        virtual_height = height + height_offset * 2
        virtual_depth = depth + depth_offset * 2

        puts "模型尺寸: #{width} x #{height} x #{depth}"
        puts "虚拟框尺寸: #{virtual_width} x #{virtual_height} x #{virtual_depth}"

        begin

          @virtual_box_group = @model.active_entities.add_group

          w2 = virtual_width / 2.0
          h2 = virtual_height / 2.0
          d2 = virtual_depth / 2.0

          front_points = [
            [-w2, h2, -d2],
            [w2, h2, -d2],
            [w2, h2, d2],
            [-w2, h2, d2]
          ]
          front_face = @virtual_box_group.entities.add_face(front_points)
          @faces << front_face

          back_points = [
            [w2, -h2, -d2],
            [-w2, -h2, -d2],
            [-w2, -h2, d2],
            [w2, -h2, d2]
          ]
          back_face = @virtual_box_group.entities.add_face(back_points)
          @faces << back_face

          right_points = [
            [w2, -h2, -d2],
            [w2, h2, -d2],
            [w2, h2, d2],
            [w2, -h2, d2]
          ]
          right_face = @virtual_box_group.entities.add_face(right_points)
          @faces << right_face

          left_points = [
            [-w2, h2, -d2],
            [-w2, -h2, -d2],
            [-w2, -h2, d2],
            [-w2, h2, d2]
          ]
          left_face = @virtual_box_group.entities.add_face(left_points)
          @faces << left_face

          top_points = [
            [-w2, h2, d2],
            [w2, h2, d2],
            [w2, -h2, d2],
            [-w2, -h2, d2]
          ]
          top_face = @virtual_box_group.entities.add_face(top_points)
          @faces << top_face

          bottom_points = [
            [-w2, -h2, -d2],
            [w2, -h2, -d2],
            [w2, h2, -d2],
            [-w2, h2, -d2]
          ]
          bottom_face = @virtual_box_group.entities.add_face(bottom_points)
          @faces << bottom_face

          transparent_material = @model.materials.add("VirtualBoxMaterial")
          transparent_material.color = [150, 200, 255]  
          transparent_material.alpha = 0.5  

          @faces.each do |face|
            face.material = transparent_material
            face.back_material = transparent_material

            face.edges.each do |edge|
              edge.visible = true
              edge.hidden = false
            end

            face.visible = true
            face.hidden = false

          end

          local_center = local_bounds.center

          move_to_local_center = Geom::Transformation.translation(local_center)
          final_transformation = transformation * move_to_local_center

          @virtual_box_group.transformation = final_transformation

          world_z_positive = Geom::Vector3d.new(0, 0, 1)

          face_to_hide = nil
          max_dot_product = -2.0  

          @faces.each do |face|

            local_normal = face.normal
            local_normal.normalize!

            origin = Geom::Point3d.new(0, 0, 0)
            normal_point = origin + local_normal
            transformed_origin = final_transformation * origin
            transformed_normal_point = final_transformation * normal_point

            world_normal = Geom::Vector3d.new(
              transformed_normal_point.x - transformed_origin.x,
              transformed_normal_point.y - transformed_origin.y,
              transformed_normal_point.z - transformed_origin.z
            )
            world_normal.normalize!

            dot_product = world_normal % world_z_positive

            if dot_product > max_dot_product
              max_dot_product = dot_product
              face_to_hide = face
            end
          end

          if face_to_hide
            face_to_hide.hidden = true
            face_to_hide.edges.each { |edge| edge.hidden = true }

            @faces.delete(face_to_hide)
            puts "已隐藏世界坐标Z轴正方向的面（顶面），法向量点积: #{max_dot_product}"
          else
            puts "警告：未找到世界坐标Z轴正方向的面"
          end

          world_z_negative = Geom::Vector3d.new(0, 0, -1)
          @bottom_face = nil
          max_dot_product_bottom = -2.0

          all_faces = @virtual_box_group.entities.grep(Sketchup::Face)
          all_faces.each do |face|
            local_normal = face.normal
            local_normal.normalize!

            origin = Geom::Point3d.new(0, 0, 0)
            normal_point = origin + local_normal
            transformed_origin = final_transformation * origin
            transformed_normal_point = final_transformation * normal_point

            world_normal = Geom::Vector3d.new(
              transformed_normal_point.x - transformed_origin.x,
              transformed_normal_point.y - transformed_origin.y,
              transformed_normal_point.z - transformed_origin.z
            )
            world_normal.normalize!

            dot_product = world_normal % world_z_negative

            if dot_product > max_dot_product_bottom
              max_dot_product_bottom = dot_product
              @bottom_face = face
            end
          end

          if @bottom_face
            puts "已找到底面（Z轴负方向），法向量点积: #{max_dot_product_bottom}"
          else
            puts "警告：未找到底面"
          end

          @virtual_box_group.visible = true
          @virtual_box_group.hidden = false
          @virtual_box_group.locked = false  

          @virtual_box_group.name = "VirtualBox_#{Time.now.to_i}"

          @faces.each_with_index do |face, index|
            puts "面 #{index + 1}: ID=#{face.entityID}, 可见=#{face.visible?}, 隐藏=#{face.hidden?}"
          end

          box_bounds = @virtual_box_group.bounds

          puts "虚拟框创建成功，组ID: #{@virtual_box_group.entityID}"
          puts "虚拟框包含 #{@faces.length} 个面"
          puts "虚拟框组已创建，可见性: #{@virtual_box_group.visible?}, 隐藏: #{@virtual_box_group.hidden?}"
          if box_bounds && !box_bounds.empty?
            puts "虚拟框边界: 中心=#{box_bounds.center}, 尺寸=#{box_bounds.width} x #{box_bounds.height} x #{box_bounds.depth}"
          end

          true
        rescue => e
          @model.abort_operation
          puts "创建虚拟框时出错: #{e.message}"
          puts e.backtrace.join("\n")
          UI.messagebox("创建虚拟框时出错：#{e.message}", MB_OK)
          false
        end
      end

      def activate

        if @selection.empty?
          UI.messagebox("请先选择一个模型！", MB_OK)
          Sketchup.active_model.select_tool(nil)
          return
        end

        @selected_entity = @selection.first

        unless @selected_entity.is_a?(Sketchup::Group) || @selected_entity.is_a?(Sketchup::ComponentInstance)
          UI.messagebox("请选择一个组或组件！", MB_OK)
          Sketchup.active_model.select_tool(nil)
          return
        end

        @model.start_operation("虚拟框坐标轴工具", true)
        @main_operation_started = true

        if @original_entity_transform.nil?
          @original_entity_transform = @selected_entity.transformation.clone

          @original_bounds_world = @selected_entity.bounds.clone
        end

        if @original_camera.nil?
          camera = @view.camera

          @original_camera = Sketchup::Camera.new
          @original_camera.set(camera.eye, camera.target, camera.up)

          is_perspective = camera.perspective?
          @original_camera.perspective = is_perspective
          if is_perspective

            @original_camera.fov = camera.fov if camera.respond_to?(:fov)
          else

            @original_camera.height = camera.height if camera.respond_to?(:height)
          end
        end

        if create_virtual_box

          if @virtual_box_group && @virtual_box_group.valid?

            begin
              @view.zoom(@virtual_box_group)
            rescue => e

              puts "zoom方法失败，使用zoom_extents: #{e.message}"
              @view.zoom_extents
            end
          end

          @view.refresh
          @view.invalidate

          puts "虚拟框已创建，包含 #{@faces.length} 个面"
          puts "请将鼠标移动到虚拟框的面上查看高亮效果"
        else

          @model.abort_operation
          @main_operation_started = false
          UI.messagebox("创建虚拟框失败！请检查Ruby控制台的错误信息。", MB_OK)
          Sketchup.active_model.select_tool(nil)
        end
      end

      def deactivate(view)
        cleanup
      end

      def cleanup

        if @main_operation_started
          begin

            if !@entity_restored && @selected_entity && @selected_entity.valid? && @original_entity_transform
              @selected_entity.transformation = @original_entity_transform
              @entity_restored = true
              puts "已恢复模型原始位置和方向"
            end

            @model.abort_operation
            @main_operation_started = false
            puts "已取消操作，所有更改已撤销"
          rescue => e
            puts "清理时出错: #{e.message}"
          end
        else

        end

        if @original_camera
          begin
            @view.camera = @original_camera
            @view.refresh
            puts "已恢复原始相机视角"
          rescue => e
            puts "恢复相机视角时出错: #{e.message}"
          end
        end

        if @main_operation_started

        elsif @virtual_box_group && @virtual_box_group.valid?

          begin
            @model.start_operation("删除虚拟框", true)
            @virtual_box_group.erase!
            @model.commit_operation
          rescue => e
            @model.abort_operation
            puts "删除虚拟框时出错: #{e.message}"
          end
        end

        @highlighted_face = nil
        @faces.clear
        @view.invalidate
      end

      def onMouseMove(flags, x, y, view)

        ph = view.pick_helper
        ph.do_pick(x, y)
        picked_face = ph.picked_face

        if picked_face && picked_face.valid? && @virtual_box_group && @virtual_box_group.valid?

          is_bottom_face = false
          if @bottom_face && @bottom_face.valid? && picked_face.entityID == @bottom_face.entityID
            is_bottom_face = true
          end

          face_entities = picked_face.parent

          is_virtual_box_face = false

          if is_bottom_face
            is_virtual_box_face = true
          elsif @faces.include?(picked_face)
            is_virtual_box_face = true
          elsif face_entities == @virtual_box_group.entities

            is_virtual_box_face = @faces.any? { |f| f.entityID == picked_face.entityID }
          end

          @highlighted_face = is_virtual_box_face ? picked_face : nil
        else
          @highlighted_face = nil
        end

        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        picked_face = ph.picked_face

        if picked_face && picked_face.valid? && @virtual_box_group && @virtual_box_group.valid?

          if @bottom_face && @bottom_face.valid? && picked_face.entityID == @bottom_face.entityID
            handle_bottom_face_click
            return true
          end

          face_entities = picked_face.parent

          is_virtual_box_face = false

          if @faces.include?(picked_face)
            is_virtual_box_face = true
          elsif face_entities == @virtual_box_group.entities

            is_virtual_box_face = @faces.any? { |f| f.entityID == picked_face.entityID }
          end

          if is_virtual_box_face
            handle_face_click(picked_face)
            return true
          end
        end

        false
      end

      def handle_face_click(face)
        begin

          local_normal = face.normal
          local_normal.normalize!

          local_center = face.bounds.center

          box_transform = @virtual_box_group.transformation

          origin = Geom::Point3d.new(0, 0, 0)
          transformed_origin = box_transform * origin

          local_normal_point = origin + local_normal
          global_normal_point = box_transform * local_normal_point

          global_normal = Geom::Vector3d.new(
            global_normal_point.x - transformed_origin.x,
            global_normal_point.y - transformed_origin.y,
            global_normal_point.z - transformed_origin.z
          )
          global_normal.normalize!

          global_center = box_transform * local_center

          camera_distance = 1000.0  

          camera_direction = global_normal.clone
          camera_direction.reverse!
          camera_eye = Geom::Point3d.new(
            global_center.x + camera_direction.x * camera_distance,
            global_center.y + camera_direction.y * camera_distance,
            global_center.z + camera_direction.z * camera_distance
          )

          world_z_axis = Geom::Vector3d.new(0, 0, 1)

          dot_product = camera_direction % world_z_axis

          if dot_product.abs > 0.99

            global_up = Geom::Vector3d.new(0, 1, 0)
          else

            scaled_direction = Geom::Vector3d.new(
              camera_direction.x * dot_product,
              camera_direction.y * dot_product,
              camera_direction.z * dot_product
            )
            projection = world_z_axis - scaled_direction

            if projection.length < 0.001
              global_up = Geom::Vector3d.new(0, 1, 0)
            else
              global_up = projection
            end
          end
          global_up.normalize!

          camera = Sketchup::Camera.new
          camera.set(camera_eye, global_center, global_up)
          camera.perspective = false
          camera.height = 500.0
          @view.camera = camera
          @view.refresh  

          face_vertices_local = face.vertices.map { |v| v.position }
          face_vertices_world = face_vertices_local.map { |local_point| box_transform * local_point }

          right_vector = global_normal * global_up
          right_vector.normalize!

          camera_points = face_vertices_world.map do |world_point|

            relative_point = world_point - camera_eye

            x = relative_point % right_vector
            y = relative_point % global_up
            z = relative_point % global_normal

            { point: world_point, x: x, y: y, z: z }
          end

          bottom_left = camera_points.min_by { |p| [p[:x], p[:y]] }  
          bottom_left_world = bottom_left[:point]

          puts "调试：相机坐标系中的点："
          camera_points.each_with_index do |p, i|
            puts "  点#{i+1}: 世界坐标=#{p[:point]}, 相机坐标(x=#{p[:x].round(2)}, y=#{p[:y].round(2)}, z=#{p[:z].round(2)})"
          end
          puts "  选择的左下角点: 世界坐标=#{bottom_left_world}, 相机坐标(x=#{bottom_left[:x].round(2)}, y=#{bottom_left[:y].round(2)})"

          if @selected_entity.is_a?(Sketchup::Group)
            model_local_bounds = nil
            @selected_entity.entities.each do |ent|
              if ent.respond_to?(:bounds)
                ent_bounds = ent.bounds
                if model_local_bounds.nil?
                  model_local_bounds = ent_bounds
                else
                  model_local_bounds.add(ent_bounds)
                end
              end
            end
          else
            model_local_bounds = @selected_entity.definition.bounds
          end

          if model_local_bounds && !model_local_bounds.empty?
            model_width = model_local_bounds.width
            model_height = model_local_bounds.height
            model_depth = model_local_bounds.depth

            offset_ratio = 0.0001
            min_offset = 1.0.mm
            width_offset = [model_width * offset_ratio, min_offset].max
            height_offset = [model_height * offset_ratio, min_offset].max
            depth_offset = [model_depth * offset_ratio, min_offset].max

            width_diff = width_offset
            height_diff = height_offset
            depth_diff = depth_offset

            adjustment_distance = [width_diff, height_diff, depth_diff].max

            adjustment_vector = Geom::Vector3d.new(
              -global_normal.x * adjustment_distance,
              -global_normal.y * adjustment_distance,
              -global_normal.z * adjustment_distance
            )

            adjusted_bottom_left_world = bottom_left_world + adjustment_vector
          else
            adjusted_bottom_left_world = bottom_left_world
          end

          entity_transform = @selected_entity.transformation

          origin = Geom::Point3d.new(0, 0, 0)
          current_origin_world = entity_transform * origin

          x_axis_point = Geom::Point3d.new(1, 0, 0)
          y_axis_point = Geom::Point3d.new(0, 1, 0)
          z_axis_point = Geom::Point3d.new(0, 0, 1)

          world_x_axis_point = entity_transform * x_axis_point
          world_y_axis_point = entity_transform * y_axis_point
          world_z_axis_point = entity_transform * z_axis_point

          world_x_axis = Geom::Vector3d.new(
            world_x_axis_point.x - current_origin_world.x,
            world_x_axis_point.y - current_origin_world.y,
            world_x_axis_point.z - current_origin_world.z
          )
          world_y_axis = Geom::Vector3d.new(
            world_y_axis_point.x - current_origin_world.x,
            world_y_axis_point.y - current_origin_world.y,
            world_y_axis_point.z - current_origin_world.z
          )
          world_z_axis = Geom::Vector3d.new(
            world_z_axis_point.x - current_origin_world.x,
            world_z_axis_point.y - current_origin_world.y,
            world_z_axis_point.z - current_origin_world.z
          )

          world_x_axis.normalize!
          world_y_axis.normalize!
          world_z_axis.normalize!

          world_z_axis_direction = Geom::Vector3d.new(0, 0, 1)
          new_z_axis = world_z_axis_direction.clone
          new_z_axis.normalize!

          right_projection = Geom::Vector3d.new(right_vector.x, right_vector.y, 0)
          if right_projection.length > 0.001
            right_projection.normalize!
            new_x_axis = right_projection
          else

            new_x_axis = Geom::Vector3d.new(1, 0, 0)
          end
          new_x_axis.normalize!

          new_y_axis = new_z_axis * new_x_axis
          new_y_axis.normalize!

          if (new_x_axis % new_y_axis).abs > 0.001 || (new_y_axis % new_z_axis).abs > 0.001 || (new_z_axis % new_x_axis).abs > 0.001
            puts "警告：坐标轴可能不正交"
          end

          new_transform = Geom::Transformation.new(
            [new_x_axis.x, new_x_axis.y, new_x_axis.z, 0,
             new_y_axis.x, new_y_axis.y, new_y_axis.z, 0,
             new_z_axis.x, new_z_axis.y, new_z_axis.z, 0,
             adjusted_bottom_left_world.x, adjusted_bottom_left_world.y, adjusted_bottom_left_world.z, 1]
          )

          new_transform_inverse = new_transform.inverse
          adjust_transform = new_transform_inverse * entity_transform

          if @selected_entity.is_a?(Sketchup::Group)

            @selected_entity.entities.transform_entities(adjust_transform, @selected_entity.entities.to_a)
          elsif @selected_entity.is_a?(Sketchup::ComponentInstance)

            @selected_entity.definition.entities.transform_entities(adjust_transform, @selected_entity.definition.entities.to_a)
          end

          @selected_entity.transformation = new_transform

          new_bounds_world = @selected_entity.bounds
          if @original_bounds_world && new_bounds_world
            center_diff = (new_bounds_world.center - @original_bounds_world.center).length
            if center_diff > 0.001  
              puts "警告：模型中心点可能发生了变化，偏移量：#{center_diff}"
            else
              puts "验证通过：模型位置保持不变（中心点偏移：#{center_diff}）"
            end
          end

          @entity_restored = true

          if @virtual_box_group && @virtual_box_group.valid?
            @virtual_box_group.erase!
          end
          @highlighted_face = nil
          @faces.clear

          if @main_operation_started
            @model.commit_operation
            @main_operation_started = false
          end

          cleanup
          Sketchup.active_model.select_tool(nil)

        rescue => e

          if @main_operation_started
            @model.abort_operation
            @main_operation_started = false
          end
          UI.messagebox("设置坐标轴时出错：#{e.message}\n#{e.backtrace.join("\n")}", MB_OK)
        end
      end

      def handle_bottom_face_click
        begin

          box_transform = @virtual_box_group.transformation

          if @bottom_face.nil? || !@bottom_face.valid?
            UI.messagebox("无法获取虚拟框底面！", MB_OK)
            return
          end

          bottom_vertices_local = @bottom_face.vertices.map { |v| v.position }

          bottom_vertices_world = bottom_vertices_local.map { |local_point| box_transform * local_point }

          edge_lengths = []
          edge_vectors = []

          (0...bottom_vertices_world.length).each do |i|
            next_vertex = bottom_vertices_world[(i + 1) % bottom_vertices_world.length]
            current_vertex = bottom_vertices_world[i]

            edge_vector = next_vertex - current_vertex
            edge_length = edge_vector.length

            edge_lengths << edge_length
            edge_vectors << edge_vector
          end

          max_edge_index = edge_lengths.each_with_index.max[1]
          min_edge_index = edge_lengths.each_with_index.min[1]

          long_edge_vector = edge_vectors[max_edge_index]
          short_edge_vector = edge_vectors[min_edge_index]

          long_edge_vector.normalize!
          short_edge_vector.normalize!

          puts "底面长边长度: #{edge_lengths[max_edge_index]}, 短边长度: #{edge_lengths[min_edge_index]}"
          puts "底面长边向量（世界坐标）: #{long_edge_vector}"
          puts "底面短边向量（世界坐标）: #{short_edge_vector}"

          new_z_axis = Geom::Vector3d.new(0, 0, 1)
          new_z_axis.normalize!

          short_edge_projection = Geom::Vector3d.new(short_edge_vector.x, short_edge_vector.y, 0)
          if short_edge_projection.length > 0.001
            short_edge_projection.normalize!
            new_x_axis = short_edge_projection
          else

            new_x_axis = Geom::Vector3d.new(1, 0, 0)
          end
          new_x_axis.normalize!

          long_edge_projection = Geom::Vector3d.new(long_edge_vector.x, long_edge_vector.y, 0)
          if long_edge_projection.length > 0.001
            long_edge_projection.normalize!
            new_y_axis = long_edge_projection
          else

            new_y_axis = new_z_axis * new_x_axis
          end
          new_y_axis.normalize!

          if (new_x_axis % new_y_axis).abs > 0.001 || (new_y_axis % new_z_axis).abs > 0.001 || (new_z_axis % new_x_axis).abs > 0.001
            puts "警告：坐标轴可能不正交"
          end

          puts "最终坐标轴: X=#{new_x_axis}, Y=#{new_y_axis}, Z=#{new_z_axis}"

          model_bounds_world = @selected_entity.bounds
          if model_bounds_world.nil? || model_bounds_world.empty?
            UI.messagebox("无法获取模型边界框！", MB_OK)
            return
          end

          bottom_center_world = Geom::Point3d.new(
            model_bounds_world.center.x,
            model_bounds_world.center.y,
            model_bounds_world.min.z
          )

          puts "模型边界框（世界坐标）: min=#{model_bounds_world.min}, max=#{model_bounds_world.max}, center=#{model_bounds_world.center}"
          puts "模型底部中心点（世界坐标）: #{bottom_center_world}"

          new_transform = Geom::Transformation.new(
            [new_x_axis.x, new_x_axis.y, new_x_axis.z, 0,
             new_y_axis.x, new_y_axis.y, new_y_axis.z, 0,
             new_z_axis.x, new_z_axis.y, new_z_axis.z, 0,
             bottom_center_world.x, bottom_center_world.y, bottom_center_world.z, 1]
          )

          puts "新变换矩阵原点位置: #{bottom_center_world}"
          puts "新坐标轴: X=#{new_x_axis}, Y=#{new_y_axis}, Z=#{new_z_axis}"

          entity_transform = @selected_entity.transformation
          puts "当前实体变换原点: #{entity_transform.origin}"

          new_transform_inverse = new_transform.inverse
          adjust_transform = new_transform_inverse * entity_transform

          if @selected_entity.is_a?(Sketchup::Group)

            @selected_entity.entities.transform_entities(adjust_transform, @selected_entity.entities.to_a)
          elsif @selected_entity.is_a?(Sketchup::ComponentInstance)

            @selected_entity.definition.entities.transform_entities(adjust_transform, @selected_entity.definition.entities.to_a)
          end

          @selected_entity.transformation = new_transform

          new_bounds_world = @selected_entity.bounds
          if @original_bounds_world && new_bounds_world
            center_diff = (new_bounds_world.center - @original_bounds_world.center).length
            if center_diff > 0.001  
              puts "警告：模型中心点可能发生了变化，偏移量：#{center_diff}"
            else
              puts "验证通过：模型位置保持不变（中心点偏移：#{center_diff}）"
            end
          end

          @entity_restored = true

          if @virtual_box_group && @virtual_box_group.valid?
            @virtual_box_group.erase!
          end
          @highlighted_face = nil
          @faces.clear

          if @main_operation_started
            @model.commit_operation
            @main_operation_started = false
          end

          cleanup
          Sketchup.active_model.select_tool(nil)

        rescue => e

          if @main_operation_started
            @model.abort_operation
            @main_operation_started = false
          end
          UI.messagebox("设置坐标轴时出错：#{e.message}\n#{e.backtrace.join("\n")}", MB_OK)
        end
      end

      def draw(view)

        if @highlighted_face && @highlighted_face.valid? && @virtual_box_group && @virtual_box_group.valid?
          box_transform = @virtual_box_group.transformation

          vertices_local = @highlighted_face.vertices.map { |v| v.position }
          vertices_world = vertices_local.map { |local_point| box_transform * local_point }

          view.drawing_color = [255, 0, 0]  
          view.line_width = 5

          vertices_world.each_with_index do |vertex, index|
            next_vertex = vertices_world[(index + 1) % vertices_world.length]
            view.draw(GL_LINES, [vertex, next_vertex])
          end

          if vertices_world.length >= 3
            view.drawing_color = [255, 0, 0, 100]  
            triangles = triangulate_face(vertices_world)
            view.draw(GL_TRIANGLES, triangles) if triangles.length >= 3
          end
        end
      end

      def triangulate_face(vertices)
        triangles = []
        return triangles if vertices.length < 3

        (1..vertices.length - 2).each do |i|
          triangles << vertices[0]
          triangles << vertices[i]
          triangles << vertices[i + 1]
        end

        triangles
      end

      def getCursor
        @cursor_id ||= UI.create_cursor(
          File.join(File.dirname(__FILE__), "cursor.png"), 0, 0
        ) rescue nil
        @cursor_id || 0
      end
    end

    def self.start_tool
      model = Sketchup.active_model

      selection = model.selection
      if selection.empty?
        UI.messagebox("请先选择一个模型！", MB_OK)
        return
      end

      tool = VirtualBoxTool.new
      model.select_tool(tool)
    end
  end

  unless file_loaded?(__FILE__)

    menu = UI.menu('Plugins')
    submenu = menu.add_submenu('渲染图片低模')

    submenu.add_item('5向图片') {
      tool = AutoRenderTool.new
      tool.execute(:five_views)
    }

    submenu.add_item('面向相机图片') {
      tool = AutoRenderTool.new
      tool.execute(:face_camera)
    }

    submenu.add_item('居中图片') {
      tool = AutoRenderTool.new
      tool.execute(:centered)
    }

    submenu.add_item('坐标轴下移') {
      AutoRender.move_local_axis_to_bottom
    }

    submenu.add_item('坐标轴工具') {
      AutoRender::VirtualBoxTool.start_tool
    }

    file_loaded(__FILE__)
  end
end
